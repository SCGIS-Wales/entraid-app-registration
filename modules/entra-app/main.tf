// Reusable module: creates an Entra Enterprise App from a parameters JSON
// document conforming to ../../parameters/parameters.schema.json.
//
// This module is the *Terraform equivalent* of the Python provisioner.
// You can use either path: pure Terraform when the consumer prefers
// declarative state, or the Lambda when invoked from Unity Deploy.
//
// Both paths produce the same result against Entra ID. The module is
// intentionally thin so the canonical schema lives in ONE place
// (parameters.schema.json), not in HCL.

locals {
  // Read and parse the parameters JSON. jsondecode is the canonical way
  // to load structured input into Terraform without leaking it through
  // tfvars.
  params = jsondecode(file(var.parameters_path))

  spa_uris          = local.params.platforms.spa.enabled ? local.params.platforms.spa.redirectUris : []
  web_uris          = local.params.platforms.web.enabled ? local.params.platforms.web.redirectUris : []
  public_uris       = local.params.platforms.publicClient.enabled ? local.params.platforms.publicClient.redirectUris : []
  api_enabled       = try(local.params.exposedApi.enabled, false)
  identifier_uris   = local.api_enabled && try(local.params.exposedApi.identifierUri, "") != "" ? [local.params.exposedApi.identifierUri] : []
  scopes            = local.api_enabled ? try(local.params.exposedApi.scopes, []) : []
  app_roles         = local.api_enabled ? try(local.params.exposedApi.appRoles, []) : []
  obo_known_clients = try(local.params.obo.enabled, false) ? try(local.params.obo.knownClientApplicationIds, []) : []

  fic_set = {
    for fic in try(local.params.federatedCredentials, []) : fic.name => fic
  }

  // Microsoft Graph well known IDs. Mirror of the Python provisioner map.
  ms_graph_app_id = "00000003-0000-0000-c000-000000000000"

  ms_graph_delegated = {
    "User.Read"          = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
    "User.ReadBasic.All" = "b340eb25-3456-403f-be2f-af7a0d370277"
    "openid"             = "37f7f235-527c-4136-accd-4a02d197296e"
    "profile"            = "14dad69e-099b-42c9-810b-d002981feec1"
    "email"              = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0"
    "offline_access"     = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"
    "Group.Read.All"     = "5f8c59db-677d-491f-a6b8-5f174b11ec1d"
    "Directory.Read.All" = "06da0dbc-49e2-44d2-8312-53f166ab848a"
  }

  ms_graph_application = {
    "Application.Read.All"            = "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30"
    "Application.ReadWrite.OwnedBy"   = "18a4783c-866b-4cc7-a460-3d5e5662c884"
    "AppRoleAssignment.ReadWrite.All" = "06b708a9-e830-4db3-a914-8e69da51d44f"
    "User.Read.All"                   = "df021288-bdef-4463-88db-98f22de89214"
    "Group.Read.All"                  = "5b567255-7703-4780-807c-7be8301ae99b"
  }

  // Build the resource access rows for required permissions.
  graph_permissions = flatten([
    for permission in local.params.requiredPermissions : (
      permission.resource == "MicrosoftGraph" ? concat(
        [for name in try(permission.delegated, []) : {
          id   = local.ms_graph_delegated[name]
          type = "Scope"
        }],
        [for name in try(permission.application, []) : {
          id   = local.ms_graph_application[name]
          type = "Role"
        }],
      ) : []
    )
  ])
}

// The calling identity (SP in CI, user locally) needs to own every app it
// creates so it can keep managing it via Application.ReadWrite.OwnedBy.
// Without this, azuread_service_principal.this hangs indefinitely because
// the SP cannot see the application it just created.
data "azuread_client_config" "current" {}

// Stable scope IDs across runs. Random is OK because the provider
// preserves it in state across applies.
resource "random_uuid" "scope" {
  for_each = { for scope in local.scopes : scope.value => scope }
}

resource "random_uuid" "app_role" {
  for_each = { for role in local.app_roles : role.value => role }
}

resource "azuread_application" "this" {
  display_name     = local.params.displayName
  description      = "Provisioned via Terraform from parameters JSON. Change ticket: ${local.params.changeTicket}."
  sign_in_audience = local.params.signInAudience

  owners = [data.azuread_client_config.current.object_id]

  identifier_uris = local.identifier_uris

  notes = format(
    "Managed=terraform App=%s Env=%s BU=%s ChangeTicket=%s Owner=%s",
    local.params.appName,
    local.params.environment,
    local.params.businessUnit,
    local.params.changeTicket,
    local.params.owner.primaryContact,
  )

  tags = concat(
    [
      "app-name:${local.params.appName}",
      "environment:${local.params.environment}",
      "business-unit:${local.params.businessUnit}",
      "change-ticket:${local.params.changeTicket}",
      "owner:${local.params.owner.primaryContact}",
    ],
    [for key, value in try(local.params.tags, {}) : "${key}:${value}"],
  )

  group_membership_claims = try([local.params.groupMembershipClaims], null)

  api {
    requested_access_token_version = local.params.tokenVersion
    known_client_applications      = local.obo_known_clients

    dynamic "oauth2_permission_scope" {
      for_each = { for scope in local.scopes : scope.value => scope }
      content {
        id                         = random_uuid.scope[oauth2_permission_scope.key].result
        value                      = oauth2_permission_scope.value.value
        type                       = oauth2_permission_scope.value.type
        admin_consent_display_name = oauth2_permission_scope.value.adminConsentDisplayName
        admin_consent_description  = oauth2_permission_scope.value.adminConsentDescription
        user_consent_display_name  = try(oauth2_permission_scope.value.userConsentDisplayName, null)
        user_consent_description   = try(oauth2_permission_scope.value.userConsentDescription, null)
        enabled                    = true
      }
    }
  }

  dynamic "app_role" {
    for_each = { for role in local.app_roles : role.value => role }
    content {
      id                   = random_uuid.app_role[app_role.key].result
      value                = app_role.value.value
      display_name         = app_role.value.displayName
      description          = app_role.value.description
      allowed_member_types = app_role.value.allowedMemberTypes
      enabled              = true
    }
  }

  web {
    redirect_uris = local.web_uris
    dynamic "implicit_grant" {
      for_each = try(local.params.platforms.web.implicitGrant, null) == null ? [] : [local.params.platforms.web.implicitGrant]
      content {
        access_token_issuance_enabled = try(implicit_grant.value.accessToken, false)
        id_token_issuance_enabled     = try(implicit_grant.value.idToken, false)
      }
    }
  }

  single_page_application {
    redirect_uris = local.spa_uris
  }

  public_client {
    redirect_uris = local.public_uris
  }

  required_resource_access {
    resource_app_id = local.ms_graph_app_id
    dynamic "resource_access" {
      for_each = local.graph_permissions
      content {
        id   = resource_access.value.id
        type = resource_access.value.type
      }
    }
  }

  dynamic "optional_claims" {
    for_each = try(local.params.optionalClaims, null) == null ? [] : [local.params.optionalClaims]
    content {
      dynamic "id_token" {
        for_each = try(optional_claims.value.idToken, [])
        content {
          name      = id_token.value.name
          essential = try(id_token.value.essential, false)
        }
      }
      dynamic "access_token" {
        for_each = try(optional_claims.value.accessToken, [])
        content {
          name      = access_token.value.name
          essential = try(access_token.value.essential, false)
        }
      }
      dynamic "saml2_token" {
        for_each = try(optional_claims.value.saml2Token, [])
        content {
          name      = saml2_token.value.name
          essential = try(saml2_token.value.essential, false)
        }
      }
    }
  }
}

resource "azuread_service_principal" "this" {
  client_id = azuread_application.this.client_id

  app_role_assignment_required = false

  owners = [data.azuread_client_config.current.object_id]

  feature_tags {
    enterprise = true
  }
}

resource "azuread_application_federated_identity_credential" "this" {
  for_each = local.fic_set

  application_id = azuread_application.this.id
  display_name   = each.value.name
  description    = try(each.value.description, "")
  audiences      = [each.value.audience]
  issuer         = each.value.issuer
  subject        = each.value.subject
}

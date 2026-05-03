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

  // Map of resource_app_id -> list of {id, type} permission entries.
  // For "MicrosoftGraph" entries, names are resolved via the lookup tables
  // above. For any other resource (a downstream Entra app's appId GUID),
  // delegated/application arrays must contain raw scope/role GUIDs that the
  // consumer reads from the downstream app's oauth2PermissionScopes / appRoles.
  // Schema disallows multiple entries with the same `resource`; if violated,
  // Terraform errors with a duplicate map key.
  permissions_by_resource_raw = {
    for permission in try(local.params.requiredPermissions, []) :
    (permission.resource == "MicrosoftGraph" ? local.ms_graph_app_id : permission.resource) => concat(
      permission.resource == "MicrosoftGraph" ? [
        for name in try(permission.delegated, []) : { id = local.ms_graph_delegated[name], type = "Scope" }
        ] : [
        for guid in try(permission.delegated, []) : { id = guid, type = "Scope" }
      ],
      permission.resource == "MicrosoftGraph" ? [
        for name in try(permission.application, []) : { id = local.ms_graph_application[name], type = "Role" }
        ] : [
        for guid in try(permission.application, []) : { id = guid, type = "Role" }
      ],
    )
  }

  // Filter out resources with zero permissions — azuread_application requires
  // at least one resource_access block per required_resource_access entry.
  permissions_by_resource = {
    for k, v in local.permissions_by_resource_raw : k => v if length(v) > 0
  }

  pre_authorized = try(local.params.preAuthorizedApplications, [])

  // Resolve permissions per resource for the consent layer below.
  // Each entry has: resource (original "MicrosoftGraph"|UUID), resource_id (resolved GUID).
  permissions_resolved = [
    for permission in try(local.params.requiredPermissions, []) : merge(permission, {
      resource_id = permission.resource == "MicrosoftGraph" ? local.ms_graph_app_id : permission.resource
    })
  ]

  // Unique resource_ids — used to look up each downstream service principal.
  unique_resource_ids = toset([for p in local.permissions_resolved : p.resource_id])

  // Application role assignments to grant. Each is keyed by "<resource>/<role>"
  // so duplicate declarations collapse cleanly.
  app_role_assignments = flatten([
    for p in local.permissions_resolved : (
      p.resource == "MicrosoftGraph" ? [
        for name in try(p.application, []) : {
          resource_id = p.resource_id
          role_id     = local.ms_graph_application[name]
        }
        ] : [
        for guid in try(p.application, []) : {
          resource_id = p.resource_id
          role_id     = guid
        }
      ]
    )
  ])

  // Delegated scopes to admin-consent, grouped by resource_id. For MS Graph
  // the consumer supplies friendly names; for any other resource the consumer
  // supplies scope GUIDs which we translate to names by reading the
  // downstream SP's oauth2_permission_scopes (the resource expects names, not
  // IDs, in claim_values).
  delegated_grants_by_resource = {
    for resource_id in local.unique_resource_ids : resource_id => flatten([
      for p in local.permissions_resolved :
      p.resource_id == resource_id ? (
        p.resource == "MicrosoftGraph" ? try(p.delegated, []) : [
          for guid in try(p.delegated, []) :
          lookup(
            { for s in data.azuread_service_principal.downstream[resource_id].oauth2_permission_scopes : s.id => s.value },
            guid,
            guid // fall through with the GUID; the resource will fail with a clear error
          )
        ]
      ) : []
    ])
  }
}

// Look up each downstream resource's service principal once. Used to resolve
// the resource_object_id for app role assignments and to translate scope GUIDs
// to names for delegated permission grants.
data "azuread_service_principal" "downstream" {
  for_each = local.unique_resource_ids

  client_id = each.value
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

  dynamic "required_resource_access" {
    for_each = local.permissions_by_resource
    content {
      resource_app_id = required_resource_access.key
      dynamic "resource_access" {
        for_each = required_resource_access.value
        content {
          id   = resource_access.value.id
          type = resource_access.value.type
        }
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

// Pre-authorised client applications (OBO + downstream API pattern). Listing a
// client app's appId here means users of that client never see a consent
// prompt for the listed scopes when calling this app; consent is implicit.
resource "azuread_application_pre_authorized" "this" {
  for_each = { for entry in local.pre_authorized : entry.appId => entry }

  application_id       = azuread_application.this.id
  authorized_client_id = each.value.appId
  permission_ids       = each.value.delegatedScopeIds
}

// Admin consent on application permissions: each declared `application` entry
// becomes an app role assignment from this app's SP onto the resource SP.
// Requires the pipeline SP to hold AppRoleAssignment.ReadWrite.All on Graph.
resource "azuread_app_role_assignment" "this" {
  for_each = { for a in local.app_role_assignments : "${a.resource_id}/${a.role_id}" => a }

  app_role_id         = each.value.role_id
  principal_object_id = azuread_service_principal.this.object_id
  resource_object_id  = data.azuread_service_principal.downstream[each.value.resource_id].object_id
}

// Admin consent on delegated permissions: one grant per (this SP, resource SP)
// pair carrying all declared scopes. Requires the pipeline SP to hold
// DelegatedPermissionGrant.ReadWrite.All on Graph.
//
// Note: this resource manages the *complete* set of delegated permissions for
// the (sp, resource) pair. Anything granted out-of-band that isn't in
// claim_values will be revoked at next apply.
resource "azuread_service_principal_delegated_permission_grant" "this" {
  for_each = {
    for resource_id, scopes in local.delegated_grants_by_resource : resource_id => scopes
    if length(scopes) > 0
  }

  service_principal_object_id          = azuread_service_principal.this.object_id
  resource_service_principal_object_id = data.azuread_service_principal.downstream[each.key].object_id
  claim_values                         = each.value
}

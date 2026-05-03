output "application_object_id" {
  description = "Object ID of the created Entra application."
  value       = azuread_application.this.object_id
}

output "application_client_id" {
  description = "Client ID (appId) of the created application."
  value       = azuread_application.this.client_id
}

output "service_principal_object_id" {
  description = "Object ID of the service principal."
  value       = azuread_service_principal.this.object_id
}

output "identifier_uris" {
  description = "Identifier URIs configured on the application."
  value       = azuread_application.this.identifier_uris
}

output "federated_credential_names" {
  description = "Names of all federated identity credentials provisioned for this application."
  value       = [for credential in azuread_application_federated_identity_credential.this : credential.display_name]
}

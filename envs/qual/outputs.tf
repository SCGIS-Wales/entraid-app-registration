output "apps" {
  description = "Map of app name -> created application IDs."
  value = {
    for k, m in module.apps : k => {
      application_object_id       = m.application_object_id
      application_client_id       = m.application_client_id
      service_principal_object_id = m.service_principal_object_id
      identifier_uris             = m.identifier_uris
      federated_credential_names  = m.federated_credential_names
    }
  }
}

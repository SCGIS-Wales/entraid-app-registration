locals {
  environment = "prod"

  apps_dir   = "${path.root}/../../apps/${local.environment}"
  app_files  = fileset(local.apps_dir, "*.json")
  app_inputs = { for f in local.app_files : trimsuffix(f, ".json") => "${local.apps_dir}/${f}" }
}

# Plan-time guard: every parameter file's `environment` must match this directory.
resource "terraform_data" "env_consistency" {
  for_each = local.app_inputs

  input = jsondecode(file(each.value)).environment

  lifecycle {
    precondition {
      condition     = jsondecode(file(each.value)).environment == local.environment
      error_message = "Parameter file ${each.key}.json has environment='${jsondecode(file(each.value)).environment}', expected '${local.environment}'."
    }
  }
}

module "apps" {
  source   = "../../modules/entra-app"
  for_each = local.app_inputs

  parameters_path = each.value

  depends_on = [terraform_data.env_consistency]
}

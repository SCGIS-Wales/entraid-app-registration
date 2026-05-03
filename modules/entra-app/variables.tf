variable "parameters_path" {
  type        = string
  description = "Filesystem path to a parameters JSON document conforming to parameters.schema.json. The module reads this with jsondecode and provisions accordingly."

  validation {
    condition     = can(file(var.parameters_path))
    error_message = "parameters_path must point to a readable file."
  }
}

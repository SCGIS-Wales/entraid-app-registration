variable "role_name" {
  type        = string
  default     = "entra-agent"
  description = "Name of the IAM role the agent assumes. Becomes the FIC subject in the Entra app registration."
}

variable "trusted_services" {
  type        = list(string)
  default     = []
  description = "AWS service principals allowed to assume this role (e.g. [\"lambda.amazonaws.com\", \"ecs-tasks.amazonaws.com\"]). Either this or trusted_role_arns must be non-empty."
}

variable "trusted_role_arns" {
  type        = list(string)
  default     = []
  description = "IAM role ARNs allowed to assume this role. Either this or trusted_services must be non-empty."
}

variable "entra_audience" {
  type        = string
  default     = "api://AzureADTokenExchange"
  description = "OIDC audience claim required by Entra. Do not change unless Microsoft documents a different audience."
}

variable "assertion_ttl_seconds" {
  type        = number
  default     = 900
  description = "Maximum lifetime of the AWS-issued OIDC assertion. STS caps this at 900 seconds (15 minutes)."
  validation {
    condition     = var.assertion_ttl_seconds > 0 && var.assertion_ttl_seconds <= 900
    error_message = "assertion_ttl_seconds must be in (0, 900]."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the IAM role."
}

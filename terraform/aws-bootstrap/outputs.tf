output "oidc_issuer_url" {
  description = "AWS Outbound Identity Federation issuer URL for this account. Paste into the `issuer` field of a federatedCredentials entry."
  value       = aws_iam_outbound_web_identity_federation.this.issuer_identifier
}

output "role_arn" {
  description = "ARN of the agent role. Paste into the `subject` field of a federatedCredentials entry."
  value       = aws_iam_role.agent.arn
}

output "role_name" {
  description = "Name of the agent role."
  value       = aws_iam_role.agent.name
}

output "fic_snippet" {
  description = "Drop-in snippet for the federatedCredentials entry in the Entra parameters JSON."
  value = jsonencode({
    name        = "aws-${var.role_name}"
    issuer      = aws_iam_outbound_web_identity_federation.this.issuer_identifier
    subject     = aws_iam_role.agent.arn
    audience    = var.entra_audience
    description = "AWS agent ${var.role_name} federation."
  })
}

// AWS-side bootstrap for passwordless Entra access from an AWS workload.
//
// Run once in the consumer's AWS account. Outputs the OIDC issuer URL and
// role ARN that the consumer pastes into a `federatedCredentials` entry in
// their parameters JSON. After the corresponding Entra app reg is provisioned
// by the SCGIS-Wales pipeline, the workload can mint an OIDC assertion via
// `sts:GetWebIdentityToken` and exchange it for an Entra access token using
// MSAL's `client_assertion`.
//
// This module does NOT touch Entra. It only enables Outbound Identity
// Federation on the AWS account and creates the role that the agent assumes.

locals {
  has_trust = length(var.trusted_services) > 0 || length(var.trusted_role_arns) > 0
}

// At least one of trusted_services or trusted_role_arns must be set; otherwise
// the role can never be assumed and the module is useless.
resource "terraform_data" "trust_validation" {
  input = local.has_trust

  lifecycle {
    precondition {
      condition     = local.has_trust
      error_message = "Provide at least one of trusted_services or trusted_role_arns; otherwise the role can never be assumed."
    }
  }
}

// 1. Enable Outbound Identity Federation for this AWS account (GA at
// re:Invent 2025). One-shot; subsequent applies are no-ops. The resource
// exposes the OIDC `issuer_identifier` directly.
resource "aws_iam_outbound_web_identity_federation" "this" {}

// 2. Trust policy for the agent role. Allows the configured AWS services and
// IAM roles to assume it. Consumer extends as needed.
data "aws_iam_policy_document" "assume" {
  dynamic "statement" {
    for_each = length(var.trusted_services) > 0 ? [1] : []
    content {
      sid     = "TrustServices"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "Service"
        identifiers = var.trusted_services
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.trusted_role_arns) > 0 ? [1] : []
    content {
      sid     = "TrustRoles"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = var.trusted_role_arns
      }
    }
  }
}

// 3. The IAM role the agent runs as.
resource "aws_iam_role" "agent" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  description        = "Agent role with permission to mint OIDC assertions for Entra (audience ${var.entra_audience}). Subject of the FIC on the corresponding Entra app reg."
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "basic_logs" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

// 4. Permission to mint the OIDC assertion. Conditions enforce the audience,
// the RS256 signing algorithm Entra requires, and a TTL cap.
data "aws_iam_policy_document" "mint_assertion" {
  statement {
    sid       = "MintEntraAssertion"
    effect    = "Allow"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "sts:IdentityTokenAudience"
      values   = [var.entra_audience]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:SigningAlgorithm"
      values   = ["RS256"]
    }
    condition {
      test     = "NumericLessThanEquals"
      variable = "sts:DurationSeconds"
      values   = [tostring(var.assertion_ttl_seconds)]
    }
  }
}

resource "aws_iam_role_policy" "mint_assertion" {
  name   = "mint-entra-assertion"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.mint_assertion.json
}

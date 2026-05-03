# aws-bootstrap

One-time AWS-side setup for passwordless Entra ID access from an AWS workload
(Lambda, ECS task, EKS pod, EC2 instance, Bedrock Agent, …). Enables AWS
Outbound Identity Federation on the account and creates an IAM role the
workload assumes; the role mints RS256 OIDC assertions which Entra exchanges
for access tokens via a federated identity credential.

This module is run **by the consumer in their own AWS account**. It does not
touch the SCGIS-Wales pipeline, the Entra tenant, or this repo's state.

## Prerequisites

- AWS provider 6.x (Outbound Identity Federation reached GA at re:Invent
  2025; older provider versions don't have the resource).
- Permission to create IAM roles + policies and to enable Outbound IdF in
  the target AWS account.

## Usage

```hcl
module "agent" {
  source = "github.com/SCGIS-Wales/entraid-app-registration//terraform/aws-bootstrap?ref=main"

  role_name = "scgis-bedrock-agent"

  # Pick one or both:
  trusted_services  = ["lambda.amazonaws.com"]
  # trusted_role_arns = ["arn:aws:iam::111122223333:role/some-task-role"]

  tags = {
    Project = "scgis-portal"
    Env     = "dev"
  }
}

output "fic_snippet" {
  value = module.agent.fic_snippet
}
```

After `terraform apply`:

1. Capture the outputs:
   - `oidc_issuer_url` — paste into a `federatedCredentials[].issuer`.
   - `role_arn` — paste into a `federatedCredentials[].subject`.
2. Open a PR against this repo adding (or updating) an `apps/<env>/<your-app>.json`:

```jsonc
{
  // ...
  "federatedCredentials": [
    {
      "name": "aws-scgis-bedrock-agent",
      "issuer": "<oidc_issuer_url from this module>",
      "subject": "<role_arn from this module>",
      "audience": "api://AzureADTokenExchange",
      "description": "AWS Bedrock Agent."
    }
  ]
}
```

3. Merge. The pipeline applies the Entra-side FIC.

4. Verify from the AWS workload:

```bash
ASSERTION=$(aws sts get-web-identity-token \
  --audience api://AzureADTokenExchange \
  --signing-algorithm RS256 \
  --query WebIdentityToken --output text)

curl -s -X POST "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=<your-app-client-id>" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=${ASSERTION}" \
  -d "scope=https://graph.microsoft.com/.default" \
  | jq .access_token
```

## What this module does

1. Enables AWS Outbound Identity Federation on the account
   (`aws_iam_outbound_web_identity_federation`). One-shot; subsequent applies
   are no-ops.
2. Reads the resulting OIDC issuer URL via the matching info data source.
3. Creates an IAM role with a configurable trust policy.
4. Attaches a policy that allows `sts:GetWebIdentityToken`, scoped by audience,
   forced to RS256, and capped at the configured TTL (≤ 900 seconds).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `role_name` | string | `entra-agent` | Name of the IAM role. Becomes the FIC subject. |
| `trusted_services` | list(string) | `[]` | AWS services allowed to assume the role (e.g. `["lambda.amazonaws.com"]`). |
| `trusted_role_arns` | list(string) | `[]` | IAM role ARNs allowed to assume the role. At least one of trusted_services or trusted_role_arns must be set. |
| `entra_audience` | string | `api://AzureADTokenExchange` | OIDC audience claim required by Entra. |
| `assertion_ttl_seconds` | number | `900` | Maximum lifetime of the assertion (STS caps at 900). |
| `tags` | map(string) | `{}` | Tags applied to the IAM role. |

## Outputs

| Name | Description |
|---|---|
| `oidc_issuer_url` | Paste into `federatedCredentials[].issuer`. |
| `role_arn` | Paste into `federatedCredentials[].subject`. |
| `role_name` | The role name as created. |
| `fic_snippet` | A ready-to-paste JSON object for the parameters file. |

## Caveats

- Outbound Identity Federation is a one-per-account toggle. Enabling it via
  this module is idempotent, but disabling (`terraform destroy`) can
  invalidate any other federations relying on the issuer.
- The role's trust policy is intentionally minimal. Real workloads usually
  attach an inline or managed policy granting access to the AWS services the
  agent needs (S3, Bedrock, etc.). That's out of scope for this bootstrap.

# RFC 003 — AWS Agent passwordless OIDC

| Field          | Value                |
| -------------- | -------------------- |
| Status         | Accepted             |
| Date           | 2026-05-03           |
| Schema version | 2.0                  |
| Depends on    | [Master RFC](RFC.md) |

## What this is

An AWS-resident workload — Lambda, ECS task, EKS pod, EC2 instance, Bedrock
Agent — that authenticates to Entra ID and calls Microsoft Graph (or any
Entra-protected API) **without holding any Entra client secret or
certificate**. The trust chain is:

```
AWS workload  ──assumes──▶  IAM role  ──sts:GetWebIdentityToken──▶  AWS-issued JWT (RS256)
                                                                              │
                                                                              ▼
                                                                  POST  /oauth2/v2.0/token
                                                                  client_assertion_type=jwt-bearer
                                                                              │
                                                                              ▼
                                                                  Entra validates against
                                                                  the federated identity
                                                                  credential (FIC) trusting
                                                                  this role ARN
                                                                              │
                                                                              ▼
                                                                       Entra access token
```

No secret on either side. The Entra app trusts AWS the same way it trusts
GitHub Actions: a federated identity credential keyed on issuer + subject.

## Prerequisites (per-consumer, per-AWS-account)

The AWS-side bootstrap is a one-time operation **the consumer runs in their
own AWS account**, with the [`terraform/aws-bootstrap`](../terraform/aws-bootstrap/)
module shipped in this repo. It enables AWS Outbound Identity Federation
on the account (GA at re:Invent 2025) and creates an IAM role with
permission to mint RS256 OIDC assertions scoped to
`api://AzureADTokenExchange`.

```hcl
module "agent" {
  source = "github.com/SCGIS-Wales/entraid-app-registration//terraform/aws-bootstrap?ref=main"

  role_name        = "scgis-bedrock-agent"
  trusted_services = ["lambda.amazonaws.com"]   # or ["ecs-tasks.amazonaws.com"], etc.

  tags = {
    Project = "scgis-portal"
    Env     = "dev"
  }
}

output "fic_snippet" { value = module.agent.fic_snippet }
```

After `terraform apply`, the outputs `oidc_issuer_url` and `role_arn` are
the two values that go into the federatedCredentials entry on the matching
Entra app reg.

## What goes in the parameters file

```jsonc
{
  // ... usual envelope ...
  "federatedCredentials": [
    {
      "name": "aws-scgis-bedrock-agent",
      "issuer": "https://<uuid>.tokens.sts.global.api.aws",
      "subject": "arn:aws:iam::<account-id>:role/scgis-bedrock-agent",
      "audience": "api://AzureADTokenExchange",
      "description": "AWS Bedrock Agent."
    }
  ],
  "requiredPermissions": [
    {
      "resource": "MicrosoftGraph",
      "delegated": [],
      "application": ["User.Read.All"]
    }
  ]
  // No platforms.spa, no platforms.web — this is a confidential client
  // (it never has a browser redirect URI). All flags false.
}
```

Application permissions (not delegated) are correct here: the agent acts
*as itself*, not on behalf of a user. The pipeline auto-grants admin consent
on these (post PR #4).

A working example lives at [`parameters/examples/aws-agent.json`](../parameters/examples/aws-agent.json).

## Wiring (workload-side, illustrative)

### Python (Bedrock Agent action group, or any Lambda)
```python
import boto3
import msal

ENTRA_TENANT  = "bc96f6fe-104f-4e22-9fbe-022bfe395457"
AGENT_APP_ID  = "<client_id of the Entra app reg>"

# 1) Mint the AWS-issued OIDC assertion for the Entra audience.
sts = boto3.client("sts")
assertion = sts.get_web_identity_token(
    Audience="api://AzureADTokenExchange",
    SigningAlgorithm="RS256",
)["WebIdentityToken"]

# 2) Hand the assertion to MSAL as the client credential.
app = msal.ConfidentialClientApplication(
    client_id=AGENT_APP_ID,
    authority=f"https://login.microsoftonline.com/{ENTRA_TENANT}",
    client_credential={"client_assertion": assertion},
)
result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
graph_token = result["access_token"]

# 3) Call Graph.
import requests
me_users = requests.get(
    "https://graph.microsoft.com/v1.0/users?$top=1",
    headers={"Authorization": f"Bearer {graph_token}"},
).json()
```

### Plain bash (smoke test)
```bash
ASSERTION=$(aws sts get-web-identity-token \
  --audience api://AzureADTokenExchange \
  --signing-algorithm RS256 \
  --query WebIdentityToken --output text)

curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=${AGENT_CLIENT_ID}" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=${ASSERTION}" \
  -d "scope=https://graph.microsoft.com/.default" \
| jq -r .access_token
```

A successful response is a JWT of ~1.6 KB that decodes to `aud: graph`,
`tid: <your tenant>`, `app_displayname: <your agent>`, `roles: [User.Read.All, …]`.

## Verification

After `terraform/aws-bootstrap` apply (in AWS) and the parameters PR merge
(in Entra):

1. Entra portal → App registrations → \<your agent\> → Certificates &
   secrets → Federated credentials: confirm one entry pointing at the AWS
   issuer URL with subject = your role ARN.
2. From the AWS side, run the bash snippet above. It returns a Graph token.
3. → API permissions: each declared application permission shows green
   "Granted for \<tenant\>" (admin consent landed).

## Caveats

- **STS TTL is 900 seconds.** The `assertion_ttl_seconds` cap in the
  bootstrap module reflects an STS hard limit. Refresh on each call (the
  workload pays sub-millisecond CPU).
- **Outbound IdF is per-account.** Enabling it via `terraform/aws-bootstrap`
  affects the whole AWS account. `terraform destroy` disables it, which
  could break other federations. Don't destroy lightly.
- **Subject is the role ARN.** Different consumers in the same AWS account
  need separate IAM roles to get separate FICs. Don't share a role across
  multiple Entra apps.
- **Bedrock Agent specifics.** AWS Bedrock AgentCore may issue assertions
  with an extended subject (`<role-arn>/AgentCore/<agent-id>` or similar) —
  verify against AWS documentation for the specific runtime, and adjust the
  FIC subject accordingly. The plain Lambda role-ARN form covered here works
  for direct sts:GetWebIdentityToken calls from any AWS workload that
  assumes the role.

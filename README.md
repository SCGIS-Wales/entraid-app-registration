# entraid-app-registration

Self-service Entra ID application registration as code.
GitHub Actions runs Terraform against `parameters/parameters.schema.json`-shaped
JSON files to create one Entra app + service principal + federated credentials
per file, across three environments. Admin consent on declared permissions
is granted automatically.

## Use cases

- **[Master RFC](docs/RFC.md)** — architecture, schema rationale, security review.
- **[RFC 001 — SPA](docs/rfc-001-spa.md)** — browser app via PKCE, no secret.
- **[RFC 002 — OBO middle-tier API](docs/rfc-002-obo.md)** — server-side API
  exchanging user tokens for downstream tokens.
- **[RFC 003 — AWS Agent passwordless OIDC](docs/rfc-003-aws-agent-passwordless.md)**
  — AWS-resident workload (Lambda, ECS, EKS, Bedrock Agent) authenticating
  to Entra via AWS Outbound Identity Federation. AWS-side bootstrap module
  lives at [`terraform/aws-bootstrap/`](terraform/aws-bootstrap/).

Working parameters JSON examples for each are in
[`parameters/examples/`](parameters/examples/).

```
PR opens                       merge to main
   |                                |
   v                                v
terraform plan (dev)          apply dev → qual → prod
   |                                |    (qual + prod gated on
   v                                |     reviewer approval; prod
plan posted on PR               waits 5 min in addition)
```

## Adding or updating an Entra app

1. Drop a JSON file into `apps/<env>/<app-name>.json` matching `parameters/parameters.schema.json`.
   Use `parameters/parameters.example.json` as a starting point. The file's
   `environment` field must match the directory it lives in.
2. Open a PR. The `terraform-plan` workflow validates the JSON, runs
   `terraform plan` against `dev`, and posts the diff as a PR comment.
3. Merge to `main`. The `terraform-apply` workflow applies `dev` unattended,
   then `qual` after your approval, then `prod` after a second approval and a
   5-minute wait.

Removing an app: delete the file and merge. Terraform will destroy the
application + service principal + federated credentials.

## Layout

| Path                                  | Purpose                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------ |
| `parameters/parameters.schema.json`   | JSON Schema for app definitions. Single source of truth.                 |
| `parameters/parameters.example.json`  | Working example, kept in sync with the schema.                           |
| `apps/<env>/*.json`                   | One file per app per environment.                                        |
| `modules/entra-app/`                  | Reusable module: parameters JSON → app + SP + FICs.                      |
| `envs/<env>/`                         | Per-environment Terraform root (one state file per env).                 |
| `.github/workflows/terraform-plan.yml`  | PR plan against dev. Validates schema. Posts plan comment.             |
| `.github/workflows/terraform-apply.yml` | Sequential apply on merge: dev → qual → prod with environment gates.   |

## Authentication

GitHub Actions authenticates to Azure via OIDC federated credentials. Each
environment has its own service principal in the Entra tenant
`dejangregorgmail.onmicrosoft.com`:

| Environment | Service principal             |
| ----------- | ----------------------------- |
| dev         | `sp-gh-entraid-tf-dev`        |
| qual        | `sp-gh-entraid-tf-qual`       |
| prod        | `sp-gh-entraid-tf-prod`       |

Each SP holds `Application.ReadWrite.OwnedBy` on Microsoft Graph (the
pipeline can manage only the apps it created) and `Storage Blob Data
Contributor` on its own state container.

No GitHub secrets are required. All values used by the workflows are
GitHub Variables (client/tenant/subscription IDs, state backend coordinates).

## Local development

```bash
cd envs/dev
terraform init -backend=false       # validate-only, no state
terraform validate

# Validate any new app JSON against the schema
python3 -c '
from jsonschema import Draft202012Validator
import json, sys
schema = json.load(open("../../parameters/parameters.schema.json"))
data   = json.load(open(sys.argv[1]))
[print(e.message) for e in Draft202012Validator(schema).iter_errors(data)]
' apps/dev/your-app.json
```

To run a full plan against the live backend (auth as a human via `az login`):

```bash
az login --tenant bc96f6fe-104f-4e22-9fbe-022bfe395457
cd envs/dev
terraform init \
  -backend-config="resource_group_name=rg-tfstate-entraid" \
  -backend-config="storage_account_name=sttfstateentraid89fb5b" \
  -backend-config="container_name=tfstate-dev" \
  -backend-config="key=entraid.tfstate"
terraform plan
```

## Admin consent

The pipeline grants admin consent on every permission a parameters file
declares — application permissions become `azuread_app_role_assignment` and
delegated permissions become `azuread_service_principal_delegated_permission_grant`.
The per-env pipeline SP holds `AppRoleAssignment.ReadWrite.All` and
`DelegatedPermissionGrant.ReadWrite.All` on Microsoft Graph for this.

Note that the delegated-permission-grant resource manages the **complete** set
of delegated permissions for each (this SP, resource SP) pair. Permissions
granted out of band (e.g. via the portal) that aren't in the parameters file
will be revoked at the next apply.

## Limitations

- **Single tenant**: dev/qual/prod share one Entra tenant; isolation is via
  display-name prefixes embedded in each app's `displayName`. If you need
  hard tenant isolation, fork the repo per tenant or extend the schema.
- **`Application.ReadWrite.OwnedBy`**: each pipeline SP can only mutate apps
  it owns. Importing an app created outside the pipeline requires either
  adding the SP as an owner (in the portal) or temporarily granting
  `Application.ReadWrite.All`.
- **Cross-API perms order of operations**: if app A declares delegated
  permissions on app B (the OBO pattern), app B must already exist in the
  tenant before app A's plan runs — the module looks up B's service principal
  by appId at plan time. Provision the downstream API first, then the
  middle-tier.

# RFC: Self-service Entra ID app registration for SCGIS Wales

| Field          | Value                                                   |
| -------------- | ------------------------------------------------------- |
| Status         | Accepted                                                |
| Author         | Dejan Gregor                                            |
| Date           | 2026-05-03                                              |
| Schema version | 2.0                                                     |
| Adapted from   | upstream `entra-app-provisioner/docs/RFC.md` (TRP, 2026)|

## 1. Summary

A federation-only path for managing Entra ID application registrations as
code. A parameters JSON document conforming to
`parameters/parameters.schema.json` becomes one Entra application + service
principal + federated credentials + admin-consented permissions, applied by
GitHub Actions through OIDC across `dev`, `qual`, and `prod`. No long-lived
secrets exist anywhere — neither in GitHub, nor in the SCGIS-Wales pipeline,
nor in apps managed by the pipeline.

## 2. Goals

| Goal                                                  | Met by                                                                      |
| ----------------------------------------------------- | --------------------------------------------------------------------------- |
| Self-service for application teams                    | Drop a JSON file into `apps/<env>/`, open a PR.                             |
| No long-lived secrets in the platform                 | OIDC throughout (GitHub → Azure for the pipeline; AWS → Entra for agents).  |
| Idempotent                                            | Terraform's create-or-update; FICs reconciled by name.                      |
| Auditable                                             | Every change is a PR; `changeTicket` field is required by the schema.       |
| Light operator footprint                              | One module + three env wirings. ~300 lines of HCL total.                    |
| Reusable across consumer types                        | Same module covers SPA, OBO middle-tier, AWS Agent (use-case RFCs 1–3).     |

## 3. Non-goals

- Provisioning Azure resources beyond the Entra app itself (no AKS, no Functions, no Key Vault).
- Cross-tenant or B2B scenarios.
- Vault / Secrets Manager integration for application secrets — there are
  none to store.
- A Lambda or ECS provisioning path. The upstream design's AWS Lambda + Unity
  Deploy + ECS bridge (RFC 5.1 in the original) was deliberately dropped:
  SCGIS-Wales has no Unity-Deploy-equivalent, and the only AWS surface in
  scope is the consumer-side `terraform/aws-bootstrap/` module that
  provisions the trust for an AWS-resident agent (RFC 003).

## 4. Architecture

```
                          GitHub PR
                              │
                              ▼
             ┌───────────────────────────────────┐
             │  terraform-plan.yml               │
             │  ─ schema validation              │
             │  ─ terraform fmt                  │
             │  ─ terraform plan (dev)           │
             │  → comment plan on PR             │
             └────────────────┬──────────────────┘
                              │ merge to main
                              ▼
             ┌───────────────────────────────────┐
             │  terraform-apply.yml              │
             │  apply dev → qual → prod          │
             │  qual + prod gated by reviewer    │
             └────────────────┬──────────────────┘
                              │ Azure OIDC (GitHub Actions)
                              ▼
                  ┌───────────────────────────┐
                  │  Microsoft Graph          │
                  │  /applications            │
                  │  /servicePrincipals       │
                  │  /oauth2PermissionGrants  │
                  │  /appRoleAssignedTo       │
                  │  /federatedIdentity...    │
                  └───────────────────────────┘
```

### 4.1 Identity flow (GitHub → Azure)

1. The job declares `permissions: id-token: write`. GitHub mints an OIDC
   token for the workflow.
2. The job sets `environment: <env>`, which makes the OIDC subject claim
   `repo:SCGIS-Wales/entraid-app-registration:environment:<env>`.
3. The hashicorp/azuread provider, with `use_oidc = true`, exchanges that
   token for an Azure access token via the federated identity credential
   on the `sp-gh-entraid-tf-<env>` app registration.
4. Terraform calls Microsoft Graph as that service principal.

The pipeline SP holds:

- `Application.ReadWrite.OwnedBy` — manage apps it created (and only those).
- `Directory.Read.All` — look up users/groups for owners and the downstream
  service principals referenced by cross-API permissions.
- `AppRoleAssignment.ReadWrite.All` — admin-consent application permissions
  on apps it owns (e.g. when an app declares `Mail.Send` as an application
  permission).
- `DelegatedPermissionGrant.ReadWrite.All` — admin-consent delegated
  permissions on apps it owns.

### 4.2 Single tenant, three environments

dev / qual / prod share one Entra tenant (`dejangregorgmail.onmicrosoft.com`,
`bc96f6fe-104f-4e22-9fbe-022bfe395457`). Isolation is via the `displayName`
field embedded in each parameters file (e.g. `myapp-dev`, `myapp-qual`,
`myapp-prod`) and a per-env Terraform state file. Three separate tenants
would triple admin overhead and isn't justified for this workload.

## 5. Schema rationale

The full schema is in [`parameters/parameters.schema.json`](../parameters/parameters.schema.json).
Highlights:

- **`appName`** — kebab-case ASCII subset of `displayName`. Used in tags,
  log keys, and identifierUri defaults. Must be immutable across re-runs.
- **`environment`** — one of `dev`, `qual`, `prod`. The pipeline asserts
  this matches the directory it lives in (`apps/<env>/<file>.json`).
- **`changeTicket`** — required; matches `^(CHG|REQ|INC)[0-9]{6,10}$`.
- **`signInAudience`** — `AzureADMyOrg` for new apps; multi-tenant requires
  separate review.
- **`requiredPermissions[].resource`** — `MicrosoftGraph` (friendly-name
  lookup) **or** any Entra app's appId GUID (raw scope/role IDs supplied
  directly). The two-branch shape is what unblocks the OBO use case.
- **`preAuthorizedApplications`** — middle-tier APIs list trusted client
  appIds + scope IDs to skip the user consent prompt. Capped at 500 (Graph
  limit).
- **`federatedCredentials`** — the federation primitive used for both
  GitHub Actions deployers (handled by the bootstrap, not consumers) and
  AWS-resident agents (RFC 003). Capped at 20 per app (Graph limit).

## 6. Use cases (per-RFC)

- **[RFC 001 — SPA](rfc-001-spa.md)**: a browser app authenticating users via
  PKCE (no secret, no implicit grant).
- **[RFC 002 — OBO middle-tier API](rfc-002-obo.md)**: a server-side API that
  receives a user's access token and calls a downstream API on the user's
  behalf. Covers exposed scopes, pre-authorised clients, cross-API permissions.
- **[RFC 003 — AWS Agent passwordless OIDC](rfc-003-aws-agent-passwordless.md)**:
  an AWS workload (Lambda, ECS, EKS, Bedrock Agent, …) authenticating to
  Entra via AWS Outbound Identity Federation, with no secrets on either side.

## 7. Security review

| Threat                                | Mitigation                                                         |
| ------------------------------------- | ------------------------------------------------------------------ |
| Stolen client secret                  | There are none.                                                    |
| Stolen GitHub token                   | OIDC; tokens are issuance-bound to repo + environment + branch.    |
| Stolen AWS role                       | FIC subject is the role ARN; rotating the role invalidates trust.  |
| Replay of stale assertion             | 900s STS TTL; Entra rejects expired tokens.                        |
| Privilege escalation via Graph        | `Application.ReadWrite.OwnedBy` — pipeline cannot touch apps it    |
|                                       | did not create.                                                    |
| Console clickops drift                | Drift detection deferred (RFC §9 of upstream); meanwhile a quarter |
|                                       | review is recommended.                                             |
| Insider via parameters JSON           | `changeTicket` required, full PR audit trail.                      |

## 8. Operational runbook

- **Adding an app**: drop a JSON in `apps/<env>/`, open a PR. Plan check
  posts the diff; merge applies it.
- **Removing an app**: delete the file, merge. Apply destroys it (soft-delete
  in Entra, recoverable for 30 days).
- **Token acquisition error `AADSTS70021`**: FIC subject mismatch. Either
  the GitHub workflow context changed (env name, repo owner) or the
  bootstrap SP's federated credential subject is stale.
- **Apply hangs on `azuread_service_principal`**: the calling SP isn't
  recorded as owner of the app it just created. The module sets owners
  explicitly via `azuread_client_config.current.object_id`; if the data
  source returns the wrong identity, check the OIDC token claims.
- **State lock stuck**: cancel the workflow, then
  `az storage blob lease break --account-name <sa> --container-name tfstate-<env> --blob-name entraid.tfstate --auth-mode key`.

## 9. Open questions

1. **Drift detection** — a nightly `plan` job that fails on drift would
   catch console clickops. Defer to a follow-up.
2. **Group-claim filtering for SPA** — Entra returns a graph link rather
   than inline group IDs above ~200 group memberships. Document a "groups
   filter" pattern in RFC 001 once needed.
3. **OBO refresh-token hygiene** — Entra's default 90-day refresh tokens are
   fine for most middle-tier APIs; if a tenant has stricter policy, document
   the override.
4. **Bedrock Agent specifics** — RFC 003 uses the canonical Lambda role-ARN
   subject. AWS Bedrock AgentCore may issue a slightly different subject
   format; verify when the first consumer integrates.

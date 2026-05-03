# RFC 002 — On-Behalf-Of (OBO) middle-tier API

| Field          | Value                |
| -------------- | -------------------- |
| Status         | Accepted             |
| Date           | 2026-05-03           |
| Schema version | 2.0                  |
| Depends on    | [Master RFC](RFC.md) |

## What this is

A server-side API (the "middle tier") that:

1. **Receives** a user's access token from a client (typically a SPA, RFC 001).
2. **Calls** one or more downstream APIs *on behalf of the user* — each call
   carries a downstream-specific access token derived from the inbound user
   token via the OAuth 2.0 token exchange grant
   (`urn:ietf:params:oauth:grant-type:jwt-bearer`).

Used whenever a server needs to act with the user's identity (not its own)
against a downstream resource — Microsoft Graph, an internal API, anything
exposing OAuth scopes.

## The three Entra apps in play

```
┌──────────────┐       SPA token      ┌────────────────────┐    OBO token   ┌────────────────────┐
│  SPA client  │  ─────(scope MT)──▶  │  Middle-tier API   │ ──(scope DS)──▶│  Downstream API     │
│  (RFC 001)   │                      │  (this RFC)        │                │  (separate app reg) │
└──────────────┘                      └────────────────────┘                └────────────────────┘
```

- **Client (SPA)** — RFC 001. Acquires a token with a scope on the middle tier.
- **Middle tier** — this RFC. Has both `exposedApi.scopes` (the scopes the SPA
  asks for) AND `requiredPermissions` (the downstream scopes it consumes
  on behalf of the user).
- **Downstream API** — a separate app registration that exposes its own
  scopes. May be Microsoft Graph or any custom Entra-protected API.

## What goes in each parameters file

### Downstream API
- `exposedApi.enabled = true` and `identifierUri = "api://your-downstream-id"`.
- `exposedApi.scopes` — the scopes the downstream offers.
- `signInAudience = "AzureADMyOrg"`, `tokenVersion = 2`.

### Middle tier
- `exposedApi.enabled = true` and `identifierUri = "api://your-middle-tier-id"`.
- `exposedApi.scopes` — what the SPA can request from the middle tier.
- `obo.enabled = true` and `obo.knownClientApplicationIds = [<SPA client_id>]`
  — tells Entra to pre-aggregate the SPA's consent into the middle tier's
  consent screen.
- `preAuthorizedApplications` — list the SPA's appId + the IDs of the
  middle-tier scopes it pre-consents to. This is what skips the user's
  consent prompt entirely for trusted callers.
- `requiredPermissions` declares the downstream scopes:
  ```jsonc
  "requiredPermissions": [
    {
      "resource": "<downstream-app-id-as-uuid>",
      "delegated": ["<scope-id-from-downstream>"],
      "application": []
    }
  ]
  ```
  The pipeline auto-grants admin consent for these (post-PR #4).

A working example lives at [`parameters/examples/obo-middle-tier-api.json`](../parameters/examples/obo-middle-tier-api.json).

## Order of provisioning

**Provision the downstream first.** The middle-tier's `requiredPermissions`
references the downstream's appId GUID, and the pipeline's `data
"azuread_service_principal" "downstream"` lookup must find a real SP. If the
downstream doesn't yet exist, the middle-tier plan errors with
`No service principal found with that client_id`.

Concretely:

1. Open PR adding `apps/<env>/downstream-api.json`. Merge.
2. Take note of the downstream's `client_id` from the apply outputs (visible
   in `envs/<env>/outputs.tf`).
3. Open a second PR adding `apps/<env>/middle-tier-api.json` with
   `requiredPermissions[].resource = <that client_id>`. Merge.

Same order for `preAuthorizedApplications.appId` (the SPA must exist before
being pre-authorised).

## Token-exchange wiring (server-side, illustrative)

```python
import msal
import requests

# 1) Receive the user token from the inbound SPA call.
inbound_token = request.headers["Authorization"].removeprefix("Bearer ")

# 2) Exchange for a downstream-scoped token using OBO.
mt = msal.ConfidentialClientApplication(
    client_id="<middle-tier client_id>",
    authority="https://login.microsoftonline.com/<tenant_id>",
    # The middle tier authenticates itself via federation; no secret.
    client_credential={"client_assertion": fetch_aws_assertion()},  # see RFC 003
)
result = mt.acquire_token_on_behalf_of(
    user_assertion=inbound_token,
    scopes=["api://<downstream-id>/<scope-name>"],
)
downstream_token = result["access_token"]

# 3) Call the downstream.
response = requests.get(
    "https://downstream/api/things",
    headers={"Authorization": f"Bearer {downstream_token}"},
)
```

The middle tier's own credential is whatever its parameters file declares —
typically a federated credential (RFC 003) when the middle tier runs in AWS,
or a workload identity if it runs in Azure. Never a client secret.

## Verification

After both files apply:

1. Entra portal → App registrations → middle tier → API permissions:
   - Each declared delegated scope is listed.
   - Each shows green "Granted for \<tenant\>" (admin consent landed).
2. → Expose an API: confirm `identifierUri` and the scopes you declared.
3. → Expose an API → "Authorized client applications": confirm the SPA
   appears with the right scope IDs (this is `preAuthorizedApplications`).
4. → Manifest: `"knownClientApplications": ["<spa-app-id>"]` is set
   (this is `obo.knownClientApplicationIds`).

End-to-end token test: from the SPA, call the middle tier with a token
acquired for `api://<middle-tier-id>/<scope>`. The middle tier exchanges it
via `acquire_token_on_behalf_of` for a downstream token. Decode the
downstream token and verify its `aud` is the downstream API's appId and
its `scp` claim contains the requested scope.

## Caveats

- **Cross-API GUIDs are obscure.** The `requiredPermissions[]` for a custom
  downstream API needs the downstream's *scope IDs* (UUIDs), not names. Read
  these off the downstream's `oauth2PermissionScopes` after it's provisioned.
  The schema enforces UUID format, so typos surface early.
- **`Application.ReadWrite.OwnedBy` ownership scope** — if the middle tier
  is created by the pipeline, the pipeline SP owns it and can keep updating
  it. If it was created elsewhere and you need to switch it onto this
  pipeline, add the pipeline SP as an owner (Entra portal → \<app\> → Owners)
  before the first apply. Otherwise the pipeline sees it as someone else's
  app and refuses to touch it.
- **Delegated permission grant manages the full set.** The
  `azuread_service_principal_delegated_permission_grant` resource owns the
  *complete* set of delegated permissions for a (this SP, resource SP) pair.
  Anything granted out of band that isn't in the parameters file gets
  revoked at the next apply. Decide where consent lives — in the pipeline
  or in the portal — and keep it consistent.

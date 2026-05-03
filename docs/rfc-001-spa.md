# RFC 001 — SPA (Single-Page Application)

| Field          | Value                |
| -------------- | -------------------- |
| Status         | Accepted             |
| Date           | 2026-05-03           |
| Schema version | 2.0                  |
| Depends on    | [Master RFC](RFC.md) |

## What this is

A browser-based SPA (React, Vue, Angular, vanilla JS) that authenticates
the user against Entra and obtains an access token for downstream APIs. No
client secret, no implicit grant — purely the OAuth 2.0 authorisation
code flow with PKCE, which is the only pattern Entra still permits for
public clients in 2026.

## Why this is the simplest path

- Browser cannot hold a client secret, so we don't try.
- PKCE is built into MSAL.js (`@azure/msal-browser`).
- Token v2 returns an access token that any modern Microsoft Graph or
  custom-API consumer can validate against Entra's JWKS endpoint.

## What goes in the parameters file

- `platforms.spa.enabled = true` and `redirectUris = ["https://your-app/auth/callback", "http://localhost:3000/auth/callback"]`.
- `platforms.web.enabled = false`, `platforms.publicClient.enabled = false`.
- `signInAudience = "AzureADMyOrg"` (single tenant) and `tokenVersion = 2`.
- `requiredPermissions[]` listing the delegated Graph (or other API) scopes
  the SPA needs. For a basic profile-read SPA: `["User.Read", "openid", "profile", "offline_access"]`.
- Optional: `optionalClaims.idToken: [{name: "groups", essential: false}]`
  to surface group memberships in the ID token.

A working example lives at [`parameters/examples/spa-public-app.json`](../parameters/examples/spa-public-app.json).

## How the pipeline behaves

The pipeline will:

1. Create an `azuread_application` with `single_page_application { redirect_uris = […] }`.
2. Create the matching `azuread_service_principal`, owned by the pipeline SP.
3. Admin-consent the listed delegated permissions (so users won't see the
   consent screen on first sign-in).

After apply, the app is visible in the Entra portal under
**Microsoft Entra ID → App registrations → \<your app\> → Authentication**
with a "Single-page application" entry containing your redirect URIs.

## Client-side wiring (illustrative)

```ts
import { PublicClientApplication, EventType } from "@azure/msal-browser";

const msal = new PublicClientApplication({
  auth: {
    clientId: "<client_id from Terraform output>",
    authority: "https://login.microsoftonline.com/bc96f6fe-104f-4e22-9fbe-022bfe395457",
    redirectUri: "http://localhost:3000/auth/callback",
  },
  cache: { cacheLocation: "sessionStorage", storeAuthStateInCookie: false },
});

await msal.initialize();
const account = msal.getAllAccounts()[0]
  ?? (await msal.loginPopup({ scopes: ["User.Read"] })).account;
const { accessToken } = await msal.acquireTokenSilent({
  account,
  scopes: ["User.Read"],
});
```

## Verification

After the parameters file applies:

1. Entra portal → App registrations → \<your app\> → Authentication: confirm
   the SPA platform exists with both redirect URIs.
2. → API permissions: confirm each declared delegated scope shows the green
   "Granted for \<tenant\>" tick (admin consent landed).
3. From a browser dev console, run the MSAL snippet above. A successful
   `acquireTokenSilent` returns a JWT whose payload contains
   `aud: "00000003-0000-0000-c000-000000000000"` (Microsoft Graph),
   `tid: "bc96f6fe-…"`, and the requested scope claims.

## Caveats

- **Group claim size limit**: Entra emits up to ~200 group IDs inline in the
  `groups` claim. Above that, the token contains a Graph link instead. If
  your app routes by group membership and your users are in many groups,
  filter the claim source via a security group + the `groupMembershipClaims`
  field. Out of scope here.
- **Token v2 only**: don't set `tokenVersion = 1`; v1 tokens use `accessToken`
  in different shapes and require explicit upgrade work later.
- **Implicit grant**: leave both flags false (`access_token: false`,
  `id_token: false`). The schema's `platforms.web.implicitGrant` exists
  for migrating legacy apps; new SPAs never need it.

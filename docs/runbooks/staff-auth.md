# Staff sign-in and recovery

VGAS-001 uses a single-tenant Entra confidential Web registration. Keep
`VGAS_STAFF_AUTH_ENABLED` unset or `false` until the Entra owner and
VGAS-9 verifier complete the live checks below. The login routes require an
HTTPS request and valid runtime configuration. `/health` remains available
when staff sign-in is off.

| Setting | Required value |
| --- | --- |
| `VGAS_STAFF_AUTH_ENABLED` | The exact value `true` enables staff routes. |
| `VGAS_ENTRA_TENANT_ID` | Approved tenant UUID. This determines the Microsoft v2 issuer. |
| `VGAS_ENTRA_CLIENT_ID` | Approved Web application client UUID. |
| `VGAS_ENTRA_CLIENT_SECRET` | Inject the registration credential through the environment's secret store. |
| `VGAS_ENTRA_REDIRECT_URI` | Exact HTTPS URL registered for `/staff/entra/callback`, without query or fragment. |
| `SECRET_KEY_BASE` | Endpoint key from the environment's secret store. Use at least 64 bytes. |

## Invite the first administrator

The registration owner verifies the signed Entra `iss`, pairwise `sub`,
`tid` and `aud` for the exact app registration in an approved, isolated
verification flow. Verify the token's signature and protocol claims using the
approved tenant metadata before using its subject. The owner confirms the
person and explicitly approves the initial **ADMIN** grant. Keep the allowlist
record in protected operator storage. Email, UPN, object ID, groups and token
roles convey no local authority.

The protected JSON document has exactly five members. Include `issuer`,
`subject`, `tenant_id`, `client_id` and `roles`. The `roles` array must
contain only `ADMIN`. Preserve the exact subject text. Use a restricted input
file or an approved secret-store pipe. Pass the document only via standard
input, outside the repository and out of command arguments and logs.

Run the local command in the intended DevCore environment.

```sh
devcore-project doctor
devcore-project run dev -- env -u OPENAI_API_KEY mise exec -- mix vgas.staff.bootstrap < "$VGAS_APPROVED_INVITATION_FILE"
```

Release operators run the same bootstrap code in the intended runtime environment.

```sh
PHX_SERVER=false bin/voelgoed_ai eval '
  {:ok, _} = Application.ensure_all_started(:voelgoed_ai)
  :ok = VoelgoedAi.Accounts.StaffBootstrap.from_stdin()
' < "$VGAS_APPROVED_INVITATION_FILE"
```

The command takes a PostgreSQL transaction lock before checking that the staff
table is empty. It commits one INVITED administrator and its provisioning audit
event together. A second invocation fails if any staff row exists. The operator
can bootstrap with the routes off. Staff receive access only after a verified
callback commits activation. Use the same owner-verification process before an
active administrator provisions another identity through the Accounts API.
Confirm the local role mapping with the business owners. Each local role
grants its own permission, including when someone holds ADMIN.

## Session and account recovery

- Sign in at `GET /staff/entra`. A successful callback renews the encrypted
  Secure, HttpOnly, SameSite=Lax cookie. The local session expires after ten
  minutes. The first GET response from `/staff/session` supplies the session's
  own staff projection and the CSRF token for `POST /staff/sign-out`. Send the
  token as `x-csrf-token`. Sign-out only clears the browser cookie. A copied
  cookie stays valid until its 600-second session expiry unless an administrator
  bumps its generation by disabling the account or changing its roles.
- A callback consumes its pending OIDC state before exchange. Pending sign-ins
  are local to the single application instance and expire after 600 seconds.
  If that instance restarts, start sign-in again. The instance holds at most
  10,000 pending sign-ins. At that cap new sign-ins get the generic denial until
  callbacks or expiry free space. Route rate limiting is a VGAS-9 gate.
- `Governance.staff_security_history/2` returns the first 100 events for one
  staff ID, oldest first, without saying whether more exist. Use it for
  recent-account review only, not as a complete audit export.
- Staff management checks the administrator's current role, state, expiry,
  registration and generation under lock. A real role change, disable,
  reactivation or retirement increments the target's generation. Subsequent
  requests deny stale credentials, including after restoring a previous role.
  Reactivation requires the same owner-verified identity and explicit roles
  for the current registration. The staff member signs in again.
- If Entra is unavailable or the registration is suspect, keep staff access
  disabled. The infrastructure operator can set the availability flag to
  `false` and reload the affected instance through the approved operational
  process. Confirm the staff route denies access and check `/health`. Repair
  the configuration under the registration owner's direction. Changing the
  registration invalidates existing sessions and requires verified allowlist
  identities for the new registration. If all local administrators are
  unavailable, keep staff access inhibited pending an owner-approved audited
  recovery procedure.
- Preserve the staff and audit tables during an application rollback. Keep
  retired identities and their history. Use disposable targets for any
  destructive schema rollback trial. G029 proposes 90 days for ordinary
  operational metadata and a separately approved schedule for security records.
  Obtain the information owner's approval for retention, recovery and purge
  before production use.

Apply the [staff telemetry subscriber and export rules](staff-knowledge.md#telemetry-subscribers-and-export)
to sign-in and session diagnostics.

## VGAS-9 and production gates

[A-011](../spec/VGAS_SPEC_v1.0.0.md#amendment-a-011--vgas-001-authentication-release-candidate-exception)
permits the exact locked AshAuthentication 5.0.0-rc.18,
ash_authentication_phoenix 3.0.0-rc.12 and Assent 0.3.2 chain for this slice.
The amendment replaces the dependency decision document planned at
`docs/decisions/VGAS-001-auth-dependencies.md`.
Recheck for a patched, compatible stable chain before VGAS-9 and again before
production. Run the full authentication suite after any authentication pin
change. Keep the live checks and production approval separate.

- Obtain tenant-owner approval for the isolated Web registration, callback,
  `client_secret_post`, consent, and dedicated test users. Verify actual
  issuer, audience, case-sensitive pairwise subject, separate tenant claim,
  and stability for that exact registration. Confirm intended roles with
  the business owners.
- Check both discovery phases, Microsoft endpoint paths and advertised
  authentication methods, provider key rotation, key size/count, compact
  token and response bounds, duplicate JSON handling, clock skew, future
  `iat`, and acceptable token lifetime. The local fixtures use no clock skew.
- Verify browser cookie delivery, state, PKCE, nonce, HTTPS routing through
  the approved proxy, and local denial on revocation, wrong identity and
  provider outage. Recheck staff authorization on protected LiveView events
  when that interface is added.
- Record redacted evidence separately from CI. Carry any untestable live
  negative case forward with its local fixture evidence and residual gap.
  Keep staff use off until the release owner approves the live result.

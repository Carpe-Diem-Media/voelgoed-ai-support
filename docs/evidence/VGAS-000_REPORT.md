# VGAS-000 feasibility evidence

2026-11-25. Candidate `cd40600075916d842ea527ea65b46f7a30cfc638` on
`spike/vgas-000-reqllm-config`. Credential configuration remains
`PARTIALLY_VERIFIED`. Independent exact-source review is pending.

## Credential and repository checks

- `gh repo view Carpe-Diem-Media/voelgoed-ai-support --json visibility --jq .visibility`
  returned `PUBLIC`. The candidate and this report remain local pending private
  visibility. Prior commits were preserved.
- A local scan enumerated 181 objects with
  `git cat-file --batch-all-objects --batch-check` and scanned blobs, commit
  messages and tags for the exact local OpenAI key, common provider token
  prefixes, private-key headers and credential-bearing URLs. Zero matches.
  This covers tracked history and locally retained objects at scan time.
  Pattern coverage is limited to the listed forms.
- An HTTPS `GET https://api.openai.com/v1/models` used the existing restricted
  development key. OpenAI returned HTTP 403 with a provider request ID and
  reported missing `api.model.read`. Successful authentication for model
  listing and Luna entitlement remain unverified. No credential, response
  body or paid inference or embedding request was emitted. The project owner
  must approve a key with model-read permission to repeat this check.
- Credential-free probes used
  `devcore-project run dev -- mise exec -- mix run --no-start -e ':ok'`.
  Malformed output-token and daily-budget values exited 1. Negative output
  tokens and daily budget, zero embedding dimensions and concurrency, and
  invalid generation model, embedding model and reasoning values exited 0.
  The value `TRUE` exited 0 and leaves live calls disabled because only the
  exact string `true` opts in. Semantic validation remains a prerequisite
  for wiring these settings to an inference caller.

## F01 pinned baseline

- Erlang 29.1.2 and Elixir 1.20.5. Phoenix 1.8.17, Ash 3.38.1, AshPostgres
  2.15.2, Ash AI 1.5.6, ReqLLM 1.31.0, Oban 2.24.2, AshOban 0.10.3,
  AshAuthentication 5.0.0-rc.18 and AshStateMachine 0.3.1 are pinned in
  [mix.lock](../../mix.lock). CI pins `pgvector/pgvector:0.8.4-pg18`.
  AshAuthentication is a release candidate. Staff compatibility remains
  unverified.
- `mise exec -- mix deps.get --check-locked`, `mise exec -- mix hex.audit`,
  `mise exec -- mix format --check-formatted` and
  `devcore-project run dev -- mise exec -- mix compile --warnings-as-errors`
  exited 0. Hex audit reported no retired or advisory packages.
  `env -u OPENAI_API_KEY devcore-project run test -- mise exec -- mix test`
  passed two tests, including PostgreSQL allocation and HTTP liveness.
- `devcore-project doctor` confirmed the DEV and TEST allocations on
  PostgreSQL 18.6. `devcore-project run test -- mise exec -- mix ecto.migrations`
  showed foundation migration `20261125141215` already applied. A read-only
  query using `MIX_ENV=test devcore-project run test -- mise exec -- mix run`
  confirmed the expected TEST database and role and no `vector` entry in
  `pg_available_extensions`. F01 is BLOCKED on an approved clean pgvector
  target and fresh migration evidence. No database reset was performed.
- The installed sources for ReqLLM and Ash AI match the resolved pins used
  by the credential configuration. Official package references include
  [ReqLLM.Keys 1.31.0](https://hexdocs.pm/req_llm/1.31.0/ReqLLM.Keys.html)
  and [Ash AI 1.5.6](https://hexdocs.pm/ash_ai/1.5.6/).
- Development startup emitted unset esbuild and Tailwind version warnings.
  Recorded under Plane VGAS-12, the VGAS-001 foundation ticket.

F02 and F03 remain pending on the verified F01 baseline. Plane VGAS-3 is
next in sequence and uses deterministic transport fakes to prove typed
inference and G027 reservations. F04–F06 remain pending in the approved
sequence. F07–F09 have no new external evidence in this run. Core go/no-go
remains open. No deployment or merge occurred.

## Independent assessment follow-up

The credential configuration remains `PARTIALLY_VERIFIED`. The previous
HTTP 403 remains the latest provider result. Repeat the read-only check
after the owner confirms that List models has Read permission.

### VGAS-2 database provisioning

DevCore v1.2.1's installed help documents that `activate` provisions roles,
databases and environment files on existing servers. It never recreates
the services. Compose labels for both assigned services identify
`/opt/stacks/dev-core/compose.yaml`. Both services run
`postgres:18.6-alpine` with persistent volumes. There is no project-level
image selection or extension provisioning command in the installed CLI.

To provide pgvector in shared DEV and TEST, the DevCore owner would need
to approve a replacement image for both PostgreSQL services, verify
image and volume compatibility and backups, and schedule recreation.
For F01, approve the following one-shot container instead. It matches the
CI pin, binds loopback only, and keeps its database in temporary memory.
The environment file would contain an independently generated disposable
administrator password and have mode 0600.

```sh
docker run --rm -d --name vgas-f01-pgvector \
  -p 127.0.0.1:55434:5432 \
  --tmpfs /var/lib/postgresql:rw \
  --env-file "$VGAS_F01_CONTAINER_ENV" \
  pgvector/pgvector:0.8.4-pg18@sha256:212765b63c1462883de295c4c415edcd22191b8d8d46853e86ad05d4b577a4cb
```

`docker buildx imagetools inspect pgvector/pgvector:0.8.4-pg18` resolved the
digest above. After approval, mirror CI's restricted `vgas_test` role
and empty database inside the container, enable vector as the disposable
administrator, verify availability and the installed version, then run
the repository migration and integration tests against this target.
Stop the container and remove the temporary credential file afterward.
The command has not run and shared services were not changed.

### VGAS-2 stable authentication trial

Hex release metadata confirms that AshAuthenticationPhoenix 2.17.4
accepts AshAuthentication `~> 4.15`. AshAuthentication 4.15.1 requires
Assent `> 0.2.0 and < 0.3.0`. The local
`mise exec -- mix deps.update ash_authentication ash_authentication_phoenix`
trial resolved those exact stable versions with Assent 0.2.13.
`mise exec -- mix hex.audit` reported critical EEF-CVE-2026-117656 for
that transitive release. Restored the prior manifest and lock. The
original lock resolves Assent 0.3.2 and its audit was clean. No override
was applied. The G036 stable dependency gate needs a patched stable
dependency chain or an explicit, narrow exception for the existing
release-candidate pair.

- [AshAuthentication 4.15.1 requirements](https://hex.pm/api/packages/ash_authentication/releases/4.15.1)
- [AshAuthenticationPhoenix 2.17.4 requirements](https://hex.pm/api/packages/ash_authentication_phoenix/releases/2.17.4)
- [Assent advisory](https://osv.dev/vulnerability/EEF-CVE-2026-117656)

### VGAS-3 runtime validation

The independent runtime correction is staged locally ahead of inference
work. Only the approved Luna and embedding profiles, 1536 dimensions and
reasoning effort `none` are accepted. Token and concurrency limits must
be positive. Budget values are exact nonnegative nano-USD, including
zero. Live opt-in accepts only `true` or `false`. Errors name the
variable and omit its value. Native credential lookup is unchanged.

The focused tests initially failed without the validator. The final
credential-free `devcore-project run test -- mise exec -- mix test`
passed 17 tests. DEV runtime probes rejected a negative budget and
`TRUE` (exit 1) and accepted a zero budget (exit 0). Formatting and
warnings-as-errors application compilation exited 0. Dependency
recompilation emitted an upstream deprecated `xref` configuration
warning.

F01 remains blocked. VGAS-3 typed inference and G027 reservation work
await the F01 baseline. No paid provider calls, public push, merge or
deployment occurred.

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

## F01 local DevCore image candidate

This proposal supersedes the earlier CI-image container proposal for the
isolated feasibility run. DevCore PR #10 rollout and exact-head CI are
separate from this local check. The proposed temporary deviation applies
only to F01 and ends with removal of the disposable container and its
dedicated volume. Standard VGAS development continues to use DevCore.

- `docker image inspect devcore-postgres:18.7-vector0.8.7` identified
  Linux amd64 image
  `sha256:c41ec08b3d88535cf84e705cced68f199f40410c60218be157f3435a1544a929`.
  Its metadata reports PostgreSQL 18.7. This is the local image ID, not
  proof of PR #10 exact-head CI.
- Read-only inspection of the image archive found `vector.so`,
  `vector--0.8.7.sql`, and a `vector.control` with
  `default_version = '0.8.7'`. The DevCore candidate Dockerfile references
  PostgreSQL 18.7 Alpine 3.24 and the pinned pgvector 0.8.7 source commit.
- Port `127.0.0.1:55434` had no listener at inspection time. Recheck
  immediately before binding.

Proposed commands, pending explicit authorization. The environment file
would be temporary, mode 0600, and contain a freshly generated synthetic
password independent of all DevCore credentials.

```sh
docker volume create vgas-f01-pg187-data
docker run --rm -d --name vgas-f01-pg187 --pull=never \
  --publish 127.0.0.1:55434:5432 \
  --mount type=volume,source=vgas-f01-pg187-data,target=/var/lib/postgresql \
  --env-file "$VGAS_F01_CONTAINER_ENV" \
  sha256:c41ec08b3d88535cf84e705cced68f199f40410c60218be157f3435a1544a929
```

After approval, verify the running image and database identity. Provision
a fresh disposable `vgas_test` database and restricted `vgas_test` role,
verify server version and extension availability, enable vector as the
disposable administrator, run fresh Ecto migrations and the integration
suite against port 55434, and record installed extension and SQL query
evidence. Stop the container and remove only its run-owned volume and
temporary files. No container was started for this inspection.

The prior stable dependency trial remains blocked by the Assent advisory.
An explicit G036 exception or a patched stable chain is still needed.
OpenAI model listing awaits confirmation of the key permission change.
No VGAS-3 inference or reservation work started.

## F01 authorized execution

**Local F01 PASS under the temporary G036 exception.** The owner approved
the disposable target and retained AshAuthentication 5.0.0-rc.18 with
AshAuthenticationPhoenix 3.0.0-rc.12 for VGAS-000 only. The stable trial
would select Assent 0.2.13 with critical EEF-CVE-2026-117656. The retained
chain uses Assent 0.3.2. Reassess stable pins before VGAS-001 and live
Entra. This exception grants no production authority.

- Rechecked the image ID and free port before binding. The running image
  matched `sha256:c41ec08b3d88535cf84e705cced68f199f40410c60218be157f3435a1544a929`.
  PostgreSQL reported 18.7, version number 180007. Vector was available
  as 0.8.7 and installed as 0.8.7 in the disposable database.
- The empty `vgas_test` database had zero public tables before migration.
  The login, database and owner were all `vgas_test`. Superuser, CREATEDB
  and CREATEROLE were false. `MIX_ENV=test mise exec -- mix ecto.migrate`
  applied migration `20261125141215`. Extension installation was a
  separate disposable-admin operation matching the CI setup.
- A synthetic `Postgrex.Types.define/3` probe used `Pgvector.extensions/0`
  to insert and decode two parameterized vectors as the application role.
  The cosine-distance query returned 0.0 and 1.0 in the expected order.
- `MIX_ENV=test mise exec -- mix test` passed all 17 tests against the
  disposable target. `mise exec -- mix deps.get --check-locked` and
  `mise exec -- mix hex.audit` exited 0. The audit reported no advisories.
  The lockfile SHA-256 is
  `d95546bb5684fdb06ba495e5f9b55b294113a8b96132ab8da64a834e8be935ec`.
- The first probe lacked started Postgrex dependencies. The rerun started
  Postgrex before opening the connection and repeated migration on a new
  empty volume. Cleanup waited for Docker's auto-removal to finish before
  removing the volume. The run-owned container, volume, credential files
  and loopback listener were absent at exit. Shared DevCore was unchanged.

## F02–F03 deterministic feasibility

Plane VGAS-2 is Done for the local F01 checks under the documented
exception. VGAS-3 is In Progress. The tests run without OpenAI credentials.
Their request bodies, provider responses, usage and prices are synthetic.

- **F02 PARTIAL.** Pinned Ash AI accepts the typed handoff decision and
  rejects an unknown field or invalid decision. The Req HTTP plug observed
  the Luna Responses request with a 500-token output limit, reasoning
  effort none, strict JSON schema, `store: false`, no tools and no previous
  response ID. The default structured-output mode sends a function tool
  even with Ash tools disabled. With this pin, the explicit
  `openai_structured_output_mode: :json_schema` option must be top-level.
  A synthetic HTTP 503 reached the fake exactly once with retries disabled.
  The spike configures a five-second request deadline. Actual provider
  latency, token enforcement and behavior remain unverified.
- Ash AI exposes normalized usage for valid output, but it returns an
  action error when decoding/casting fails. A direct ReqLLM fixture
  retained the provider response ID and usage. Its public response
  metadata did not retain the synthetic `x-request-id` header. ReqLLM's
  embedding API verified the model, 1536 dimensions and returned usage
  with `return_usage: true`. That result does not include a provider
  request ID. Embedding options use Req's retry flag because the pinned
  embedding API rejects `max_retries`.
- **F03 PARTIAL.** The test-only reservation ledger serializes admission
  per test process, calculates synthetic integer nano-USD ceilings, and
  reserves before invoking either operation. Tests cover daily/monthly
  and concurrency denial, zero allowance, concurrent overspend, no
  transport on denial, duplicate attempts, trusted settlement even for
  invalid output, release on proven no-send, ambiguous timeout or
  missing usage, and unresolved rollover. The test process does not
  provide PostgreSQL durability or multi-node locking. Before live
  testing, verify a PostgreSQL-backed reservation and settlement path,
  capture trusted request-level usage and correlation even on rejected
  outputs, and prove the full provider request cost bound. No live
  generation or embedding occurred.
- `mise exec -- mix format --check-formatted` and
  `devcore-project run dev -- mise exec -- mix compile --warnings-as-errors`
  exited 0. `env -u OPENAI_API_KEY devcore-project run test -- mise exec --
  mix test` passed all 30 tests on the standard TEST allocation after
  disposable F01 cleanup. The new inference tests use no live transport.
- The read-only model-list check still awaits confirmation of the
  permission change. Credential configuration remains PARTIALLY_VERIFIED.

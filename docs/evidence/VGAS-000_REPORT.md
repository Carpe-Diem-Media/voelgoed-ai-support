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

## F02–F03 durable local run

2026-11-25. VGAS-3 continues from the accepted F01 baseline and temporary
G036 exception. This run used the standard DevCore TEST allocation
(`vgas_test`, PostgreSQL 18.6). No shared service was reconfigured. The
new test-only ledger uses randomly named tables owned by the test role,
with no migration or production entry point. A post-suite query found
zero matching feasibility tables. All tests used synthetic inputs and
deterministic transports.

### F02 · Local PASS, provider verification pending

The supported seam is Req 0.7.5's `adapter` option in ReqLLM 1.31.0
`req_http_options`. Ash AI 1.5.6's `transform_flow` supplies those options
per generation attempt. ReqLLM wraps and calls the original adapter. The
spike delegates only to a local Req.Test plug. It captures a whitelisted
HTTP result before ReqLLM decoding and Ash business validation, then
returns the original result. The Ash AI generation path needed no
direct ReqLLM fallback. The existing ReqLLM embedding path uses the
same adapter.

Generation uses top-level `openai_structured_output_mode: :json_schema`,
`max_completion_tokens: 500`, `reasoning_effort: :none`,
`provider_options: [store: false]` and `max_retries: 0`. The wire request
has strict JSON schema, no tools, no previous response ID, no streaming,
and `max_output_tokens: 500`. Embedding uses `dimensions: 1536` and
`return_usage: true`, and accepts a single input. The pinned embedding
API rejects `max_retries`. Both paths disable Req retries and redirects
and set five-second whole-call and receive timeouts. A fake HTTP 503
produced one outbound invocation per attempt.

The reservation ID identifies the internal attempt. Evidence contains
the returned model, HTTP status, duration, whitelisted usage, supplied
provider request/response IDs and transport classification. The
application disposition is recorded separately, so rejected output
can still be charged. Missing identifiers remain null. If both IDs
are absent, usage is missing, or a supplied model differs, the attempt
stays unknown. A response with correlated usage can settle even on
HTTP failure. The requested allowlisted model supplies the price when
the response omits its model. No request/response bodies, prompts or
credentials are stored. Timeout is simulated after dispatch rather than
measured against OpenAI.

Source references: [Req adapter 0.7.5](https://hexdocs.pm/req/0.7.5/Req.html),
[ReqLLM 1.31.0](https://hexdocs.pm/req_llm/1.31.0/),
[Ash AI 1.5.6](https://hexdocs.pm/ash_ai/1.5.6/). Inspected installed
`ReqLLM.Transport.attach/1`, `Req.merge/2`, and
`AshAi.Actions.Prompt.apply_transform_flow/3`.

### F03 · Local PASS at spike scope, provider verification pending

The pinned Postgrex 0.23.0 path uses the existing AshPostgres Repo.
A short table-lock transaction serializes daily, monthly and concurrency
admission even with an empty ledger. Four checked-out connections with
distinct PostgreSQL backend PIDs raced for one allowance. Exactly one
reserved and three were denied. The transaction commits before dispatch.
A second committed claim fences duplicate or hidden retries. The
transport refuses an outer Repo transaction. No lock is held across
the simulated HTTP call.

The tests kill workers after reservation, after claiming possible
execution, and after the adapter commits trusted usage but before
settlement. A fresh process recovered their rows. Recovery releases
only a reservation whose state proves the worker never claimed a send.
An uncertain attempt holds its ceiling across UTC day and month rollover
and frees its local concurrency slot. Late reliable evidence can settle
an unknown attempt once. Racing settlement callers preserve one charge
and a second evidence write is rejected. Over-ceiling evidence inhibits
new claims and admissions, even before settlement. With zero allowance,
unknown pricing, a missing ledger, or a rejected wire request, no
provider transport runs. The spike recovery caller must know that the
worker returned or stopped. Production recovery needs a trusted worker
lease/fence, durable governance storage and authorized reconciliation.

Price snapshot `vgas-000-openai-standard-v1`, checked 2026-11-25,
covers the global Standard OpenAI endpoint and the two fixed profiles.
Luna's published Standard base rates are 100 input and 500 output
nano-USD per token. Admission uses 500 input and 750 output nano-USD,
covering published long-context and 12-hour cache-write rates. The
1,050,000-token full context ceiling covers instructions, history,
knowledge and schema overhead without a tokenizer estimate. The
500-token output limit includes reasoning tokens. The conservative
ceiling is 525,375,000 nano-USD. The 8192-token single embedding limit
at 20 nano-USD per token reserves 163,840 nano-USD. These conversions
are exact integers with no fractional rounding. Settlement computes
a conservative charge from reported usage and the chosen snapshot,
not an invoice amount. The Luna ceiling exceeds the default $0.25
development daily budget, so that budget would deny generation.
Lowering the reserve for a live test would require a separately verified
tighter cost bound or an explicitly approved budget.

Pricing and limits: [Luna model](https://developers.openai.com/api/docs/models/gpt-6-luna),
[OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[Responses output limit](https://developers.openai.com/api/reference/resources/responses/methods/create),
[Embedding model](https://developers.openai.com/api/docs/models/text-embedding-3-small),
[Embedding input limit](https://developers.openai.com/api/reference/typescript/resources/embeddings/methods/create).

### Commands and next gate

- `env -u OPENAI_API_KEY devcore-project run test -- mise exec -- mix test`
  exited 0 with 44 tests passed. The test suite exercises PostgreSQL
  recovery and admission plus real Ash AI/ReqLLM request handling through
  deterministic fake HTTP responses.
- `mise exec -- mix format --check-formatted`, `devcore-project run dev --
  mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix deps.get
  --check-locked`, `mise exec -- mix hex.audit`, and `git diff --check`
  exited 0. The lockfile was unchanged and Hex reported no advisories.
- `MIX_ENV=test devcore-project run test -- mise exec -- mix run` queried
  `pg_tables` in the current schema and found zero per-test spike tables.
- F04–F05 / VGAS-4 is next after the applicable local review gate. The
  ticket requires an isolated PostgreSQL target with pgvector. The prior
  disposable approval covered F01 and the shared rollout remains separate.
  Actual OpenAI model listing and provider tests remain pending. No paid
  calls, public push, merge or deployment occurred.

## VGAS-4 isolated F04–F05 run

2026-11-25. The reviewer provisionally accepted local F02–F03 at
`9a58c53`. Exact-source review and provider verification remain pending.
The uncommitted AGENTS.md edit was inspected and left outside this change.
Its delegation requirement informed a bounded planning pass. The edit
itself was neither committed nor treated as a change to the frozen
business requirements.

### Generation cost-bound follow-up

Retained the 525,375,000 nano-USD Luna reservation and the existing 32 KiB
serialized request check at the Req adapter. The byte check limits the
wire request before dispatch but does not certify provider-counted
tokens. The proposed 8,000 input and 500 output token caps would cost
1,050,000 nano-USD at uncached Standard short-context base rates.
That excludes cache-write premiums. OpenAI publishes short-context
input/output rates of $0.10/$0.50 per million, 30-minute and 12-hour
write rates of $0.125/$0.25 per million, and a long-context threshold
above 272,000 input tokens. Above it, input and cache prices double
and output rises by 1.5 times. Regional processing adds 10% where
applicable and Fast doubles the applicable rates. This spike retains
the conservative global Standard ceiling and the existing daily budget.

The OpenAI Responses input-token endpoint accepts messages, instructions
and the response schema, but the local fixture cannot prove equivalence
to the billed token count for the final provider request. The pinned
Ash AI and ReqLLM paths provide the final encoded body, not an
independently verified provider token count. An exact-request comparison
against the provider counting endpoint and metered usage would require
a separately authorized provider check. No estimate replaced the existing
reservation or wire guard, and no provider count or inference call was
made in this slice.

Sources: [Luna model and tier rules](https://developers.openai.com/api/docs/models/gpt-6-luna),
[OpenAI prompt cache and pricing](https://developers.openai.com/api/docs/pricing),
[Responses input token count](https://developers.openai.com/api/reference/resources/responses/subresources/input_tokens/methods/count).

### F04 · Local PASS

The test harness used application-controlled draft, review, approval,
queued indexing, indexing completion and publication transitions.
Approved content is frozen against its review hash. The explicit
background task claims one revision/locale/profile/hash/generation
record and runs after the database transaction commits. G027 admission
and the one-send transport claim precede each fake embedding invocation.
Approval, indexing readiness and reviewer publication are distinct
gates. A failed replacement leaves the old publication eligible. Two
separate PostgreSQL connections raced to publish with the same expected
pointer. One succeeded and the other returned `stale_pointer`.

The corpus ran 28 synthetic bilingual revisions and 56 locale embedding
jobs. The fake checked the canonical locale, content and scope payload,
1536 dimensions and committed reservation, and returned correlated
usage. Other tests covered draft edits, wrong actor and profile,
immutable content, stale hash/generation, revoked in-flight work,
wrong dimension, nonfinite input including PostgreSQL rejection of
`[NaN]`, expiry before dispatch, missing reservation storage, and
activation denial before both locales were ready.

Pinned Ash AI 1.5.6's `AshAi.EmbeddingModels.ReqLLM.generate/2` runs
the one-input native embedding path. The generic automatic/manual
vectorization change lacks the scenario's revision-state, reservation,
and generation fences. The fixture therefore wraps the native embedding
module with an explicit job and a guarded vector write through the
existing AshPostgres Repo. The queued rows and Task workers prove local
ordering. Durable Oban execution, recovery scheduling, and production
Ash authorization remain later work. No production resources or
migrations were added.

### F05 · Local PASS for retrieval mechanics

A PostgreSQL eligible-candidate CTE gates both exact pgvector cosine
and simple full-text branches by published current revision, date,
public audience, enabled collection, current grant, scope, locale,
hash and profile. Reciprocal-rank fusion uses k=60, deduplicates by
revision, breaks ties by the synthetic ID and projects at most four
records after rechecking eligibility. The tests exercised both branches,
including a case where lexical evidence reverses a cosine tie. Identical
text and vectors in internal, ungranted, disabled, expired, revoked,
wrong-scope, wrong-profile and staged revisions failed both branches.
A separate replacement test excluded the superseded revision and a grant
withdrawal emptied both result sets.

The basis vectors intentionally encode relevance. Orthogonal fixture
vectors contribute no semantic candidate. That is a fixture condition,
not a production relevance threshold. Missing or unresolved evidence
returns clarify. The 20 expectations are synthetic, author-labelled
fixtures. Staff validation and actual bilingual embedding quality
remain pending.

Observed rankings and end-to-end fixture timings follow. Empty lists
selected no evidence. The ambiguous query was stopped before search.

- `en-card` matched expected `[1]`. Cosine `[1]`, lexical `[1]`, selected `[1]`, 3235 µs.
- `af-card` matched expected `[1]`. Cosine `[1]`, lexical `[1]`, selected `[1]`, 7400 µs.
- `en-office` matched expected `[2]`. Cosine `[2]`, lexical `[2]`, selected `[2]`, 7773 µs.
- `af-parcel` matched expected `[3]`. Cosine `[3]`, lexical `[3]`, selected `[3]`, 3249 µs.
- `mixed-delivery` matched expected `[4]`. Cosine `[4]`, lexical `[4]`, selected `[4]`, 7084 µs.
- `af-newsletter` matched expected `[5]`. Cosine `[5]`, lexical `[5]`, selected `[5]`, 3201 µs.
- `en-access` matched expected `[6]`. Cosine `[6]`, lexical `[6]`, selected `[6]`, 2723 µs.
- `af-programme` matched expected `[7]`. Cosine `[7]`, lexical `[7]`, selected `[7]`, 2914 µs.
- `en-receipt` matched expected `[8]`. Cosine `[8]`, lexical `[8]`, selected `[8]`, 3073 µs.
- `af-hours` matched expected `[9]`. Cosine `[9]`, lexical `[9]`, selected `[9]`, 2808 µs.
- `mixed-pickup` matched expected `[10]`. Cosine `[10]`, lexical `[10]`, selected `[10]`, 2497 µs.
- `typo-parking` matched expected `[11]`. Cosine `[11]`, lexical `[11]`, selected `[11]`, 2767 µs.
- `typo-transfer` matched expected `[12]`. Cosine `[12]`, lexical `[12]`, selected `[12]`, 2862 µs.
- `vector-only-typo` matched expected `[13]`. Cosine `[13]`, lexical `[]`, selected `[13]`, 2846 µs.
- `lexical-only-feedback` matched expected `[14]`. Cosine `[]`, lexical `[14]`, selected `[14]`, 2686 µs.
- `fused-account` matched expected `[19, 15]`. Cosine `[15, 19]`, lexical `[19]`, selected `[19, 15]`, 2808 µs.
- `af-lost` matched expected `[16]`. Cosine `[16]`, lexical `[16]`, selected `[16]`, 2675 µs.
- `ambiguous` matched expected `[]`. Cosine `[]`, lexical `[]`, selected `[]`, 0 µs.
- `off-topic` matched expected `[]`. Cosine `[]`, lexical `[]`, selected `[]`, 2064 µs.
- `no-relevant-af` matched expected `[]`. Cosine `[]`, lexical `[]`, selected `[]`, 5086 µs.

### Verified environment and cleanup

- Rechecked the tag against immutable image
  `sha256:c41ec08b3d88535cf84e705cced68f199f40410c60218be157f3435a1544a929`
  and confirmed port 55434 was free. Docker used `--pull=never` and
  bound only `127.0.0.1:55434`. The disposable container and dedicated
  volume were labelled F04-F05. PostgreSQL reported 18.7 and installed
  vector 0.8.7. The database, owner and role were `vgas_test` and the
  role had neither superuser nor createdb.
- Using generated credentials scoped to that target,
  `MIX_ENV=test mise exec -- mix ecto.migrate` applied
  `20261125141215` in the fresh instance. With `VGAS_F04_DISPOSABLE=1`
  and `VGAS_F04_EVIDENCE=1`, `mise exec -- mix test` passed all 49
  tests, including five pgvector and indexing tests. No OpenAI key was
  exported for the run. Focused tests first failed before the fixture
  existed. `mix format --check-formatted`, `mix compile
  --warnings-as-errors`, `mix deps.get --check-locked`,
  `mix hex.audit` and `git diff --check` exited 0 under Mise. Hex
  reported no advisories. Dependency pins were unchanged.
- After testing, a `pg_tables` query found zero spike tables. Verified
  labels before stopping the run-owned container, waited for auto-removal
  and removed only its named volume and temporary files. Docker and
  `ss -ltnH 'sport = :55434'` confirmed the resources and listener
  were gone. Shared DevCore services and databases were untouched.

VGAS-5 / F06 is the next local feasibility ticket. It uses signed
synthetic Chatwoot events, isolated PostgreSQL/Oban work and fake
reply/handoff transport. VGAS-4 awaits exact-source and staff-fixture
review. The temporary G036 exception remains feasibility-only. No
public push, merge, deployment or paid provider call occurred.

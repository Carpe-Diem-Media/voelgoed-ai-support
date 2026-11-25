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

## Post-merge independent review of VGAS-3 and VGAS-4

PR #2 merged at `324cb105d749de50b31f3ea007cabd931a915ff0` before
its exact-head Application CI finished and without a recorded review.
Independent reviewers then inspected head `1f7150d` against base
`8456cd4`. This section supersedes the earlier retry statements in
the F02–F03 sections and preserves them as history.

### Correction · ReqLLM embedding retries

The earlier claim that Req's `retry: false` disables embedding retries
was wrong. ReqLLM 1.31.0 attaches its own retry step after merging the
Req options and replaces `retry` with its policy
(`deps/req_llm/lib/req_llm/step/retry.ex`). That policy decides
whether a failure is retryable; `max_retries`, which defaults to 3,
controls the attempt limit. An offline probe with a counting adapter,
`retry: false` and a 20-second total timeout entered the adapter four
times for both a synthetic 503 and a synthetic timeout. With `max_retries: 0` in
`req_http_options` it entered once.

The merged durable path was also exposed. `TransportEvidence` calls
`Req.merge(plug: ...)`, which sets the returned request's adapter to
`Req.Plug`, so each retry bypassed the wrapper and its durable claim
and went straight to the provider. Under the uncorrected options the
independent review of PR #3 observed one wrapper entry and up to four
fake-provider calls. A synthetic timeout gave four calls with either a
5-second or a 20-second total timeout. A plain 503 gave three calls
within the 5-second deadline the regression test uses and four within
20 seconds, because retry backoff consumes the deadline. Four is the
maximum: the first attempt plus three retries. An earlier draft of
this correction wrongly called the durable path incidentally safe.

The correction adds `max_retries: 0` to both transport option sets.
Three tests now cover it: a bare-adapter counter, a fake-provider hit
counter on the durable path, and an assertion on the embedding
options captured outside the transport callback (an assertion inside
the callback is rescued as an ambiguous outcome and cannot fail the
test). With `max_retries: 0` removed from both support modules, all
three failed; with it restored, the 21 focused tests pass.

### Review outcomes

- **VGAS-3 (F02–F03).** The source supports typed native Ash AI output,
  the bounded wire request, durable admission, ambiguous-cost retention
  and the conservative ceilings. The retry finding above was the only
  blocker. Carried into VGAS-004, not feasibility blockers: let late
  trusted usage settle a row that already holds timeout evidence, by
  appending separately keyed reconciliation evidence; fence recovery of
  a `dispatching` row against the still-running ReqLLM request task;
  assert real lock waits in the admission race tests.
- **VGAS-4 (F04–F05).** Accepted with follow-ups for local mechanics.
  Ordinary CI skips the five pgvector tests because they require the
  disposable 18.7 / 0.8.7 target. The orchestrator reran them on the
  approved image at `324cb10`: 49 passed, run-owned resources removed.
  Staff-labelled retrieval outcomes remain an external VGAS-11 gate.
  Carried into VGAS-003: recheck validity at worker completion, keep
  unknown embedding outcomes out of plain requeue, assert the scope
  field and canonical hash on the wire, and test revocation between
  ranking and projection.

## F08 · Entra and staff authorisation (VGAS-6)

**PASS for local F08 (VGAS-6).** The OIDC fixture, PostgreSQL
authorisation, session denial, audit and clean build checks passed.
VGAS-9 owns proof against an authorised live Entra test registration.
The feasibility brief classifies F08 as **PARTIAL** while that live
proof is pending.

The initial 2026-11-25 run used branch `feat/vgas-6-f08-entra-authz` at base
`324cb105d749de50b31f3ea007cabd931a915ff0`. The diff for
`config`, `lib`, `test` and `mix.exs` against that base has SHA-256
`fe0ae4b9cbb3b30467253b3fabbab2dbc7a42dd4e6996e312ca6800f207d0adf`.
The lockfile SHA-256 is
`97e956eb45a003ebae63bdbe513d6ecabd187e9fd5a40f68114c732896c71867`.
Mise pinned Elixir 1.20.5 and Erlang 29.1.2. The fixture used Ash 3.38.1,
AshPostgres 2.15.2, AshAuthentication 5.0.0-rc.18,
AshAuthenticationPhoenix 3.0.0-rc.12 and Assent 0.3.2 against DevCore TEST
PostgreSQL 18.6. Every test ran without `OPENAI_API_KEY`. The fixtures
generated RSA keys in memory and routed all provider requests through
private Req.Test stubs.

Ash 3.38.1 checks for a SAT solver when it compiles a policy authorizer.
Crux 0.1.5 selects `Picosat` at compile time when available, then falls
back to `SimpleSat`. The application pins `simple_sat` 0.1.4 in all
environments so policy checks can use the solver at compile time and
runtime. This release uses pure Elixir, has no Hex dependencies and
satisfies the optional solver requirement in both Ash and Crux. Only
the solver entry changed in the lockfile.
[Hex release metadata](https://hex.pm/api/packages/simple_sat/releases/0.1.4).

### Expected and observed

- **Verified callback and activation.** The native strategy produced an
  authorization-code redirect with state, nonce and S256 PKCE. The
  fixture token stub checked the code, callback URI and verifier. Assent
  used discovery and JWKS to verify the signed token. Two concurrent
  callbacks with different provider emails selected the same local UUID
  and produced one activation and one routine login. The signed cookie
  carried the staff UUID, generation and expiry. The explicit ADMIN role
  passed the admin probe. The reviewer probe required its own role.
- **Identity and protocol denial.** A wrong or missing tenant or issuer,
  substituted discovery and token issuer, wrong, empty or missing
  subject, email-only identity, and unlisted or disabled identity all
  failed. Caller-supplied maps could not invoke sign-in successfully.
  State or callback-cookie errors stopped before code exchange. Replay
  reached the provider stub, where the code was already spent. Invalid
  nonce, audience, times, signature, key and algorithm, plus discovery,
  token and JWKS errors, all denied. Assent 0.3.2 raises for two malformed
  inputs tested here. The fixture catches only the observed Assent
  state/nonce comparison and audience enumeration errors at the callback.
- **Local revocation.** Each fresh privileged request and direct Ash
  probe checked the current staff row. An operator failed both privileged
  probes even with provider ADMIN and reviewer claims. Disable rejected
  a previously issued cookie, a stale direct action and a new valid
  sign-in. It also defeated activation with a candidate read before the
  disable committed. Demotion revoked the old cookie. Restoring the
  role left that cookie and the interim operator cookie denied. A fresh
  login used the restored role. The tests denied absent and tampered
  cookies and expired or unknown actors on direct Ash calls.
- **Audit and isolation.** A forced PostgreSQL audit constraint failure
  rolled activation back and prevented cookie issuance. Ordinary staff
  could neither write an arbitrary audit event nor invoke the raw
  transition directly. Two schema prefixes with the same provider
  subject kept staff and audit rows isolated. ExUnit teardown removed
  each generated schema. The fixture uses bootstrap-only provisioning.
  Reactivation, retirement and database outage were outside the local run.

The fixture binds the stored issuer and pairwise subject to the configured
app registration, with the exact signed tenant checked separately. After
native validation, the preparation recovers the signed issuer and tenant
from the token and checks the time claim types. Assent drops the protocol
claims from user info and its expiry check uses Elixir term ordering.
Provider email, object ID, groups and roles assign no local privilege.
A different client ID requires explicit allowlist provisioning for its
pairwise subjects. The relevant pinned implementation is
`ash_authentication/lib/ash_authentication/strategies/oauth2/plug.ex`
(`callback/2` and `action_opts/1`) and
`assent/lib/assent/strategies/oidc.ex` (`fetch_user/2` and
`validate_id_token/2`).
[OIDC Core §3.1.3.7](https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation),
[OIDC Discovery §4.3](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfigurationValidation),
[Entra ID-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference#use-claims-to-reliably-identify-a-user).

### Verification and remaining gates

- `mise exec -- mix format --check-formatted`,
  `mise exec -- mix deps.get --check-locked` and `mise exec -- mix hex.audit`
  each exited 0. Hex reported no retired or advisory packages.
- The clean TEST build reproduced `No SAT solver available` and exited
  1 before the solver pin. After adding the pin,
  `rm -rf _build/test && MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  and the DEV `mise exec -- mix compile --warnings-as-errors` each
  exited 0.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --no-color test/voelgoed_ai/entra_feasibility_test.exs --seed <seed>`
  exited 0 for seeds `0`, `17` and `2026`, with 13 passed each and no skips.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --no-color`
  exited 0 with 57 passed and five existing F04 disposable tests skipped.
- `python3 .github/scripts/plan_tests.py` exited 0 and included F08.
  `git diff --check`, `git diff --cached --check` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --staged --redact` exited 0.
  Gitleaks found no leaks. GitHub Actions on the candidate remains unverified.

### Review fixes after integrating main

The independent review of `e5f6029230ae4bf5276a596881e17baf4c8f7ad2`
found that Assent 0.3.2 used discovery endpoints before the signed-issuer
check ran. The test-only HTTP adapter now checks the discovery issuer
against the configured issuer by exact string comparison before handing
the response to Assent in either phase. It also requires authorization,
token and JWKS endpoints. Both phases return 401 with no redirect or
session for invalid discovery. A callback with valid saved state and
PKCE never reaches the fake token endpoint when discovery fails.
[OIDC Discovery §4.3](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfigurationValidation).

An authenticated staff member with an empty local role grant fails both
privileged probes despite provider role claims. For disablement and role
changes, a PostgreSQL constraint rejects the audit append. Both management
calls return an invalid `Ash.Changeset`. The transaction preserves the
staff row and the existing session's access. These tests cover the existing
role check and transaction in `EntraStore`.

With only the discovery issuer comparison removed, the request returned
302 and the callback hit the token endpoint once. Bypassing the adapter
raised a `BadMapError` on empty metadata. Omitting each required endpoint
check separately allowed a redirect or an exchange. Letting empty role
grants pass returned 204 on an admin probe that should return 403.
Removing the management transaction separately for each action caused
the persisted state assertion to fail. Each mutated ExUnit run exited 2.
All mutations were reverted.

The review-fix branch incorporates main
`a731a06a0d54d61438c6e709e5a3170e6b60b7ed`. The diff for
`config`, `lib`, `test` and `mix.exs` against that main has SHA-256
`570c6df3d262c0a668dc3641d878b50b83e6ccf2df78c5a16f8c669fdea60e17`.

Review-fix verification on DevCore TEST, with all mutations reverted:

- `mise exec -- mix format --check-formatted` and
  `rm -rf _build/test && MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  exited 0. The build emitted dependency warnings during the clean compile.
- `mise exec -- mix deps.get --check-locked` and `mise exec -- mix hex.audit`
  exited 0. Hex reported no retired packages or advisories.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --no-color test/voelgoed_ai/entra_feasibility_test.exs --seed <seed>`
  exited 0 on seeds `0`, `17` and `2026`. Each run passed all 19 F08 tests.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --no-color`
  exited 0 on seed `934318`, with 65 passed and five existing F04
  disposable-target skips.
- `python3 .github/scripts/plan_tests.py` exited 0 and included F08.
  `git diff --check`, `git diff --cached --check` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --staged --redact` exited 0.
  The staged scan found no leaks. GitHub Actions on the review-fix
  candidate remains unverified.

### Identity and discovery re-review fixes

The re-review of `e35b85af91b27489447a832a9afbd318e1a2c4e2` found
that Ash trimmed an invited subject and that Assent used malformed
discovery metadata. The fixes and five regression tests are in
`306d0015b7a39c2c98685a82f07b850fa40c82c8`.

- **Exact identity.** The fixture keeps issuer, subject and tenant text
  as supplied. Ash 3.38.1 documents `trim?` and `allow_empty?` in
  `deps/ash/lib/ash/type/string.ex`. The tenant keeps the UUID shape
  without going through Ash's trimming and lowercasing UUID cast. The
  signed tenant still has to match the configured tenant exactly. A
  PostgreSQL read returned the subject with its original space and tab.
  Signing in with the distinct unpadded subject returned 401, issued no
  session and left the row invited with only its provisioning audit event.
  The exact padded subject activated successfully on that candidate.
  The current local subject format is documented below.
- **Provider metadata.** The adapter validates all three endpoints as
  absolute HTTPS URLs with a host, a valid port and valid percent escapes.
  It rejects userinfo and fragments. An advertised authentication-method
  list must contain only strings and include the configured method.
  Assent 0.3.2 reads these fields and the issuer in this flow. Its optional
  userinfo path is unused. The fixture accepts omitted method metadata.
  Each invalid endpoint or method case returned 401 in both phases with
  no redirect, session or token exchange.

The new regressions run against DevCore TEST and private provider stubs.
Before the fixes, the focused run exited 2. It observed 204 for the
unpadded subject and a callback exception for a numeric method value.
For each mutation, the command was
`devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/entra_feasibility_test.exs:<line> --seed 0`.
Each of the 22 runs below exited 2 with 0 of 1 selected tests passing
and 23 excluded. The source was restored after each run.

- Line 64 caught subject trimming.
- Line 76 caught issuer and tenant trimming, removal of the tenant UUID
  shape check, and empty issuer or subject acceptance.
- Line 141 caught the removal of each endpoint check, the endpoint type
  check, HTTPS, the missing and empty host checks, userinfo, fragments,
  the port range, URI syntax and percent-escape checks.
- Line 163 caught removal of the method list type, item type and
  configured-method membership checks.
- Line 174 caught denial when the optional method field was absent.

The following checks ran with the mutations reverted.

- `devcore-project doctor` exited 1 with `.env.local` missing.
  `devcore-project plan` and `devcore-project activate` each exited 0.
  The second `devcore-project doctor` exited 0.
- `mise exec -- mix deps.get --check-locked`,
  `mise exec -- mix deps.unlock --check-unused`,
  `mise exec -- mix format --check-formatted` and
  `mise exec -- mix hex.audit` each exited 0. Hex reported no retired
  packages or advisories.
- `devcore-project run test -- env -u OPENAI_API_KEY env MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  exited 0.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/entra_feasibility_test.exs --seed <seed>`
  exited 0 on seeds `0`, `17` and `2026`, each with 24 passed and no skips.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test`
  exited 0 on seed `113341`, with 70 passed and five existing F04
  disposable-target skips.
- `python3 .github/scripts/plan_tests.py` included F08 and exited 0.
  `git diff --check origin/main...HEAD` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='origin/main..HEAD'`
  exited 0. Gitleaks found no leaks.

VGAS-9 still needs real tenant, app, consent and callback approval.
Its smoke test must check actual claims, browser cookie delivery, signing
keys and revocation with approved test users. A later LiveView integration
must recheck authorisation for each protected event on an existing socket.
VGAS-001 must reassess compatible patched stable AshAuthentication and
adapter pins before staff UI work or live testing. The G036 RC exception
is feasibility-only.

### Malformed provider responses and subject format

The follow-up addresses the two findings at
`5a30e1540fe200c25559e4bae6ae63728c94018c` on
`feat/vgas-6-f08-entra-authz`. The verified code is
`1b03845d127b8a1cf41498d6f9185b1f50e96676`, after
`4af4187dd1532ac6463d4865328362193ac47088` and
`f71eb42ec02e53949d6d16f62b0e74787f2296bc`. The evidence commit changes
only this section. The comparison base is `origin/main` at
`a731a06a0d54d61438c6e709e5a3170e6b60b7ed`.

The test-only HTTP adapter validates successful token and key-set
responses before Assent 0.3.2 reads them. The fixture accepts compact
RS256 JWS with a key ID and public RSA JWKs. It caps compact tokens at
32,768 bytes and individual text fields at 4,096 bytes. Assent still
checks signature, issuer, audience, expiry and nonce. Errors from
Assent's callback or the JOSE payload parser return a fixed category
and log only `entra_oidc_callback_exception`. The Ash policy and
activation run outside the rescue. A deliberately raising Req adapter
exercised the rescue at the endpoint. A separate test exercised the
JOSE parse failure.

The malformed-response matrix made 230 callback requests through
private Req.Test stubs. Each case exercised the shape validator and
returned 401 with `Sign-in denied`, no redirect, an empty session and
zero persisted activations. The staff row stayed invited and its only
audit event was provisioning.

- 95 token and header cases covered the token object, `id_token`,
  `access_token`, `token_type`, `refresh_token`, `expires_in`, `scope`,
  the protected header object, `alg`, `kid`, `typ`, `cty`, `b64` and
  `crit`. They also covered missing required members, extra or missing
  segments, invalid or empty signature encoding, an oversized compact
  JWS, an unsupported algorithm and an unencoded payload.
- 71 signed-claim cases covered the payload object, `iss`, `sub`,
  `aud`, `azp`, `exp`, `nbf`, `iat`, `nonce` and `tid`. They also
  covered missing required claims and malformed audience arrays.
- 64 key-set cases covered the JWKS object, `keys` and each key's
  `kty`, `kid`, `use`, `alg`, `n`, `e` and private `d` member.
  They also covered missing members, an empty set, invalid base64url,
  EC keys and a malformed key after a valid matching key.

The matrix applies null, a number, a list, an object, an empty string
and a 4,097-byte string to each listed field. The suite also exercises
valid optional values, `alg: none` denial, exact issuer and tenant,
discovery and client-authentication methods, empty local role grants,
audit rollback, activation concurrency and session renewal.

Invites and signed callbacks require 1–255 ASCII bytes. The local rule
also rejects ASCII controls and leading or trailing spaces. The nine
negative subject cases include a padded tab, embedded NUL and DEL.
Ash returned a subject validation error on invite, and the callback
returned the same generic 401. A valid 255-byte subject round-tripped
byte for byte and activated. Its lowercase variant did not match.
Confirm the conservative format and local response bounds against the
approved live registration in VGAS-9.
[OIDC Core §2](https://openid.net/specs/openid-connect-core-1_0.html#IDToken).

The first focused run against the old implementation, with the new
endpoint regressions, exited 2. Each subsequent mutation removed one
guard at a time. The command was
`devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/entra_feasibility_test.exs:<line> --seed 0`.
All 53 runs at `f71eb42` exited 2 with one selected test failing and
29 excluded.

- Line 85 caught eight subject mutations covering the invite and
  callback checks, nonempty and length checks, ASCII restrictions,
  controls, boundary spaces and exact Ash casting.
- Line 268 caught 21 token and header mutations covering adapter
  enforcement, document and field shapes, compact JWS limits and
  signature encoding, protected header members and shared text checks.
- Line 293 caught 11 claim mutations covering the object, each
  claim's shape and the audience list and member checks. Line 85
  independently caught the subject predicate.
- Line 310 caught 12 JWKS mutations covering adapter enforcement, set
  shape, validation of every key, RSA key type, key members and exclusion
  of private key data.
- Line 365 caught removal of the callback rescue. After the rescue
  was narrowed to the two parser calls in `1b03845`, removing it again
  made both the raising adapter at line 366 and the JOSE test at
  line 379 exit 2. Each run selected one test and excluded 30.

All mutations were reverted before verification.

- `devcore-project doctor` exited 1 with `.env.local` missing.
  `devcore-project plan` and `devcore-project activate` exited 0.
  The second `devcore-project doctor` exited 0.
- `mise exec -- mix deps.get --check-locked`,
  `mise exec -- mix deps.unlock --check-unused` and
  `mise exec -- mix format --check-formatted` exited 0.
  `mise exec -- mix hex.audit` ran separately and exited 0 with no
  retired packages or advisories.
- `devcore-project run test -- env -u OPENAI_API_KEY env MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  exited 0.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/entra_feasibility_test.exs --seed <seed>`
  exited 0 on seeds `0`, `17` and `2026`, with 31 passed and no skips
  on each run.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test`
  exited 0 on seed `983803`, with 77 passed and five existing F04
  disposable-target skips.
- `python3 .github/scripts/plan_tests.py` exited 0 and routed F08 to
  shard 4. `git diff --check origin/main...HEAD` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='origin/main..HEAD'`
  exited 0. Gitleaks reported no leaks.

Local F08 passed using synthetic identities and DevCore TEST. Live
Entra proof remains pending in VGAS-9, so F08 is still partial overall.
Independent review and CI for the published candidate remain pending.

### Independent review of 71d3069 and low-finding fixes

An independent Claude Opus 5.5 review of `71d3069` approved the code.
It found no fail-open path, crash path or authentication bypass, and
each of the 21 guard removals it tried made a committed test fail. It
raised three low findings, fixed in `cd78a33`:

- The callback rescue caught `ExUnit.AssertionError` raised by the
  provider stub, so a broken PKCE or redirect assertion could pass as an
  expected 401. The rescue now re-raises fixture assertions, and a
  regression confirms the original assertion reaches the test.
- RSA keys had no size or exponent bounds. The adapter now requires a
  2048 to 4096 bit modulus with its top bit set and exponent `AQAB`.
  Regressions deny a modulus without its top bit, 1024-bit and 4104-bit
  moduli, exponent 3, an oversized exponent and a token signed by a
  published 1024-bit key.
- Access and refresh tokens shared the 4 KiB text bound. They now use the
  32 KiB compact-token bound, and a regression accepts a 32 KiB access
  token with a 5,000-byte refresh token.

Removing the re-raise, the modulus bounds, the exponent rule or the
access-token bound each exited 2 with the targeted test failing. With
the fixes restored, the F08 file passed 34 tests on seeds `0`, `17` and
`2026`. The full suite passed 80 with five existing F04 skips on seed
`543717`. Locked and unused dependency checks, formatting, `hex.audit`,
warnings-as-errors compilation, `plan_tests.py`, `git diff --check` and
gitleaks (10 commits, no leaks) exited 0.

The review's informational notes stay open for VGAS-9: duplicate JSON
member names resolve consistently across Jason, Elixir `JSON` and JOSE;
there is no maximum token lifetime or future `iat` rule; and the signed
issuer and tenant comparisons are redundant with Assent and the database
filter, so no test isolates them.

## F06 | VGAS-5 signed Chatwoot ingress and fixed delivery

Evidence from `feat/vgas-5-f06-chatwoot-ingress`. The first follow-up started at
`c8fd5868be45807e69fe54b386595375c579abe2`. The implementation commit is
`34ff8988a391dde5a5c2c9cc8eef98e99ea8d3a9`. The next review fixes start at
`c092c05e58887a6f2243d958f767b7fa19bdcf96`. The tests use synthetic IDs and JSON, and
generate signing keys and fake API tokens in ExUnit. The test-only Phoenix
endpoint runs with `server: false`. The Req adapter has no network path.

- Toolchain and storage. Elixir 1.20.5, Erlang 29.1.2, Phoenix 1.8.17,
  Plug 1.20.4, Ecto SQL 3.14.0, Postgrex 0.23.0, Oban 2.24.2, Req 0.7.5,
  and PostgreSQL 18.6 on the DevCore TEST allocation (role and database
  `vgas_test`). The TEST role created the test-owned schema without
  CREATEDB or grants. Each test applied Oban schema version 14 and spike
  tables under its own prefix, then dropped the prefix and checked
  `pg_namespace`.
- Reference candidate. Chatwoot CE v4.18.0,
  `9f920b549c14491a4e587687a3eed5d21c6ccc7d`. The fixture follows the
  [Agent Bot listener](https://github.com/chatwoot/chatwoot/blob/9f920b549c14491a4e587687a3eed5d21c6ccc7d/app/listeners/agent_bot_listener.rb)
  and [webhook trigger](https://github.com/chatwoot/chatwoot/blob/9f920b549c14491a4e587687a3eed5d21c6ccc7d/lib/webhooks/trigger.rb).
  It signs timestamp, dot, and the original JSON bytes, with an inclusive
  300-second window in either direction and a 64 KiB body limit.
  The conversation GET fixtures follow the pinned
  [conversation serializer](https://raw.githubusercontent.com/chatwoot/chatwoot/9f920b549c14491a4e587687a3eed5d21c6ccc7d/app/views/api/v1/conversations/partials/_conversation.json.jbuilder),
  which puts `AgentBot` or `User` in `meta.assignee_type` and the ID
  in `meta.assignee.id`. The serializer omits both assignee fields for an
  unassigned CE conversation.

### Local acceptance

1. **PASS. Signed receipt and atomic dispatch (T01).** An independent
   PostgreSQL connection saw zero receipts and jobs while the transaction
   paused after enqueue. The same observer saw both rows at the before-send
   barrier, where the request had left the transaction and still owed
   its 204. Two concurrent requests held distinct backends. PostgreSQL
   reported the second backend waiting on the first. Both returned 204
   after commit. A sequential replay left one receipt and one job whose
   sole argument was the event UUIDv7.
2. **PASS. Rejection, rollback and ignored events.** Invalid key, missing,
   duplicate or malformed signing headers, changed JSON whitespace, and
   timestamps at ±301 seconds returned 401. Both ±300 boundaries passed
   with valid signatures. Malformed JSON, oversized bodies and scope
   conflicts returned 400, 413 and 403 respectively, with zero receipts
   or jobs. Outgoing bot, private, activity, attachments and unsupported
   fixtures committed ignored receipts with zero jobs. A forced rollback
   after enqueue and a database constraint rejecting the Oban insert
   each returned 500 with zero durable rows. A new signed attempt after
   the first rollback committed the pair.
3. **PASS. Guarded fixed reply, explicit handoff and ambiguous writes
   (T02, T04–T06).** Ingress, delivery and recovery used actual Oban
   inserts and manual drains. A fresh GET qualified each write. A separate
   backend observed SENDING,
   generation 1 and one attempt at the adapter boundary, with the expected
   ownership epoch and HANDOFF_PENDING for handoff. The adapter counted
   exactly one POST for each successful reply and handoff. The handoff
   test required a confirming GET, and a forced rollback restored the
   prior epoch and pending reply. A committed handoff intent cancelled the
   unsent reply. Scope drift, expired or fenced reply work, a timed-out
   reply ownership GET, newer input, resolution and human takeover
   produced zero POSTs for those paths.
   A simulated remote commit followed by timeout, disconnect, 503,
   redirect, malformed acceptance or a failed read-back each left an
   UNKNOWN intent after one POST. After Oban discarded a lost delivery
   job, the recovery job recorded UNKNOWN at claim expiry. Worker
   replays, a new event and a duplicate reconciliation job produced no
   additional POST for the unknown reply. The scheduled read-only job
   confirmed an unknown handoff at 46 seconds. The adapter recorded one
   status POST.

### Review corrections

1. **Ownership response.** A configured bot in a qualified pending
   conversation can send. Human assignment at admission or before
   delivery prevents a POST. Unassigned pending, open, resolved and
   snoozed fixtures also prevent a POST. Missing or unrecognised
   `assignee_type` denies a pending reply. Unverified handoff ownership
   records a failure and keeps the session inhibited.
2. **First human observation.** A signed human outbound event followed by a
   qualified GET showing `open` creates a durable human-owned session even
   before the first customer message. A later bot-assigned pending GET
   leaves that session human-owned with zero POSTs. The duplicate webhook
   and ingress job replay exercise the same sequence.
3. **Handoff recovery.** A reply expires 45 seconds after receipt. G013's
   five-minute handoff window starts when the intent is created. The
   first review used Oban attempts to cap pre-write reads. The worker
   can send at 46 seconds. At the handoff deadline or after the third
   failed read, it records a terminal FAILED intent with a reason code and
   keeps the session in HANDOFF_PENDING for operator inspection. The spike
   stores that signal locally. It has no staff notification integration.
   The durable write claim still allows one POST. Ambiguous writes stay
   UNKNOWN pending read-only reconciliation.

Each correction's tests were rerun with that fix temporarily reverted
while the other fixes were in place. Under seed 0, the ownership case
failed because the bot GET produced no reply intent (0/1, exit 2).
Both first-observation cases queued a reply intent (0/2, exit 2).
The five handoff tests failed on cancellation or missing preflight
retries (0/5, exit 2). All passed after restoration.

### Follow-up review corrections

1. A qualified signed public human reply commits HUMAN_ACTIVE and fences
   pending work in the receipt and enqueue transaction. A rollback undoes
   the inhibit along with the receipt and job. Later bot-assigned pending
   GETs leave the inhibit in place. Private notes and AgentBot messages
   are ignored. The pinned CE callback for opening a pending conversation
   on a human reply requires Captain. The test leaves the conversation
   pending throughout. [Chatwoot message model](https://github.com/chatwoot/chatwoot/blob/9f920b549c14491a4e587687a3eed5d21c6ccc7d/app/models/message.rb#L380-L390)
2. A public reply requires `can_reply: true`. An explicit handoff can
   open a qualified pending conversation assigned to the configured bot
   when the reply window is closed. The test records one status POST
   followed by a confirming GET. [Chatwoot status controller](https://github.com/chatwoot/chatwoot/blob/9f920b549c14491a4e587687a3eed5d21c6ccc7d/app/controllers/api/v1/accounts/conversations_controller.rb#L74-L90)
3. HTTP 429 and 5xx join transport errors and timeouts in the safe
   pre-write retry path. Handoff allows at most three preflight attempts
   over five minutes. The tests retry 429 and 503 after 46 seconds, verify
   the existing exhaustion reason, and show that a queued retry at the
   five-minute boundary makes no additional preflight request. The
   session stays inhibited after definitive failure. An ambiguous POST
   still results in UNKNOWN after one write.
4. The claim transaction schedules a separate Oban job for the five-second
   lease expiry. Recovery locks the same session and delivery rows as
   settlement and requires the matching generation in SENDING. It records
   UNKNOWN without HTTP. The test kills the actual Oban drain at the fake
   POST, observes the attempt-one job in `executing`, and runs Oban 2.24.2's
   rescue engine. It observes the exhausted job in `discarded`. The
   claim stays SENDING at four seconds, and the recovery job marks it
   UNKNOWN at five seconds. Recovery of an already settled reply is a no-op.

All five selected regressions failed against the original implementation
at `c8fd586`, then passed with the fixes restored. The selection command
was `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/chatwoot_feasibility_test.exs:453:594:613:746 --seed 0`.
It exited 2 on the original implementation, with five failures and 47
excluded. With the other fixes in place, removing each fix in isolation
also failed on the intended assertion. Each mutation used the same test
command with a single line selector.

- `:453`, receipt inhibit removed. The adapter recorded a reply POST.
  Exit 2, one failure and 51 excluded.
- `:594`, `can_reply` reapplied to handoff. The status intent failed
  before its POST. Exit 2, one failure and 51 excluded.
- `:613`, transient HTTP classification removed. The 429 and 503 tests
  observed no retry. Exit 2, two failures and 50 excluded.
- `:746`, recovery enqueue removed. The intent stayed SENDING after Oban
  discarded the delivery job. Exit 2, one failure and 51 excluded.

### Inbound receipt and delivery lifecycle

The receipt and its first Oban job commit together. The qualified message
key deduplicates signed retries and preserves the receipt time. The
decision transaction inserts any delivery intent and its deadline job.
The recurring Oban Cron job sweeps overdue receipts and intents using
PostgreSQL only. The F06 tests use the real Oban queues and rescue
engine in a disposable TEST schema. All Req calls use the fake adapter
outside transactions.

| Non-terminal state | Concurrent actors and fence | Lost, duplicate or late work | Local evidence |
|---|---|---|---|
| Inbound DISPATCHED, awaiting a decision | The original and replacement ingress jobs can read before 45 seconds. The receipt row lock orders those results with the deadline sweep. Only the first decision can update ownership and create an intent. A genuine public human reply inhibits in the receipt transaction. | A lost ingress job leaves a durable receipt for Cron. A signed replay acknowledges without enqueueing again. A replacement can decide before expiry. A terminal or expired receipt cannot admit a late GET result. Delivery recovery and reconciliation have no receipt operation. | Receipt replay and rollback tests, discarded ingress rescue and Cron, overdue original job, original and replacement race, late read with and without the sweep, and lost human observation. |
| Reply PENDING | Original and replacement delivery jobs share one ownership read. The reservation checks the deadline after locking the row and returns a sequence. Claim checks that sequence, the session epoch, active event and deadline. Deadline or Cron can cancel and release the active slot. A qualified human observation can fence the reply. | A duplicate cannot spend a second read or claim a write. A lost preflight ends in CANCELLED at the deadline. A stale or late GET cannot claim a POST. Lease recovery and reconciliation have no PENDING operation. | Duplicate delivery, late preflight, read blocked on PostgreSQL, human receipt fence, discarded preflight and Cron fallback. |
| Handoff PENDING | Original and replacement delivery jobs reserve from the same three reads. The latest reservation can claim the write while the session remains eligible. Qualified human ownership confirms the goal without POST. Qualified resolution cancels. Deadline or Cron can record definitive failure before claim. | Safe transient failures may retry within budget. A duplicate spends from that same budget and fences earlier reads. If the last preflight is lost, the deadline records FAILED and keeps the inhibit. Lease recovery and reconciliation have no PENDING operation. | Safe retry, concurrent final reservation, older preflight, discarded final preflight, replacement and deadline tests. |
| Reply SENDING | The writer rechecks the committed state, claim generation, session epoch and available lease before dispatch. Settlement checks generation, state, ownership and lease. The lease job or deadline can record UNKNOWN under the same locks. | Replacement delivery and reconciliation jobs cannot send. If Oban loses the writer, lease recovery records UNKNOWN. Deadline and Cron cover a lost lease job. A response that returns after expiry or after recovery cannot settle the reply. | Lost executing POST, replacement and reconciliation no-ops, pause at claim commit, intervening human takeover, insufficient lease, and late response tests. |
| Handoff SENDING | The same dispatch and lease rules apply. The writer can reserve a read for confirmation after POST. Settlement requires the current claim and read reservation. Deadline or recovery can record UNKNOWN and give any remaining read to reconciliation. | A replacement cannot write or spend the confirmation read. Late POST and GET results cannot take over after recovery. If the individual deadline job is lost, Cron closes the window. | Immediate confirmation, exhausted immediate read budget, lost POST, stale writer after recovery and immediate confirmation at the deadline. |
| Handoff UNKNOWN, recovery still open | Original and replacement reconciliation jobs can reserve GETs. The latest reservation can settle only while the row remains UNKNOWN, the deadline is open and no recovery failure is recorded. Deadline or Cron can close the recovery window. | A discarded reconciliation job can never cause a repeated POST. The deadline records failure if work is lost. A delayed older result cannot displace the latest reservation or a recorded failure. Delivery and lease recovery jobs cannot write here. | Lost reconciliation, replacement budget, older/newer results in both orders, latest result after deadline failure, and qualified resolution. |

An ignored receipt or a dispatched receipt with a durable decision is
terminal for ingress. SENT, FAILED and CANCELLED are terminal for
delivery. Reply UNKNOWN is terminal for automation in this spike.
Handoff UNKNOWN with a recorded recovery failure is terminal for
automated recovery. The original reason and uncertain outcome remain
available for operator review.

Under G012, a qualified `resolved` read closes the session even when
it follows our explicit `open` POST. It cannot prove that our POST
achieved the open handoff goal. Immediate confirmation and scheduled
reconciliation therefore both preserve UNKNOWN and record
`handoff_conversation_closed`. Both stop further reads and writes.
The spike never reopens a resolved conversation or auto-resolves one.

G009 separates durable dispatch from processing the receipt. G013 sets
the provisional 45-second interactive window and calls for visible
operational recovery. If a dispatched receipt missed that window,
the ingress worker or a bounded Cron sweep records
`ingress_deadline_exceeded` for operator triage. The spike cannot
establish automated handoff eligibility for an input it never safely
processed. It sends no late reply or status change and preserves any
existing inhibit, including one committed with a human reply. A
handoff already created within the interactive window retains its
separate five-minute budget under G012 and G013.

Req receive and response timeout options use the smaller of 500 ms
and the remaining applicable deadline or claim lease. The injected
clock is checked after PostgreSQL grants the read reservation lock.
Rows are unlocked before the Req adapter runs. The interval between
the final local claim check and dispatch therefore still permits a
human or recovery process to change the database, or Chatwoot to change
ownership. The timeout settings and local fences reduce that interval
without providing a remote conditional write. The bound holds only for
the fake adapter. The pinned Finch client bounds pool checkout with
`pool_timeout` and connection setup with a connect timeout, both
defaulting to 5,000 ms, separately from the receive timeout this
adapter sets. Either default alone can reach the whole lease. Finch
also documents a transparent retry when an HTTP/2 pool is draining. A real POST could therefore reach Chatwoot
after recovery has recorded UNKNOWN or after a human takeover. F07 must
bound pool checkout, connect and request time below the remaining lease
with a margin, and pin HTTP/1 or exclude that retry. F07 owns live
timeout, ownership and channel validation.

### Verification

- `devcore-project doctor` exited 0 after `devcore-project plan` and
  `devcore-project activate` created the missing local environment.
  Both bootstrap commands exited 0.
- `mise exec -- mix deps.get --check-locked`,
  `mise exec -- mix format --check-formatted`, and
  `mise exec -- mix hex.audit` each exited 0 in separate invocations.
  Hex reported no retired or advisory packages.
- `devcore-project run test -- env -u OPENAI_API_KEY env MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  exited 0.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/chatwoot_feasibility_test.exs --seed 0`
  and the same command with `--seed 371486` each exited 0, with 52 passed
  and zero skips. Both include the earlier assignee, human observation
  and handoff deadline regressions.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test`
  exited 0 at seed 175627, with 98 passed and five pre-existing F04 skips.
  The generated replay tests that this branch adds to
  `chatwoot_feasibility_test.exs` emitted compiler warnings about
  constant branches. `main` emits none. CI does not compile test files
  with warnings as errors.
- `git diff --check origin/main...HEAD` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='origin/main..HEAD'`
  exited 0. Gitleaks reported no leaks.

The Phoenix.ConnTest fixture exercised raw request bytes with the
endpoint disabled as a server. F07 still owns live status and assignment
subscriptions, response payload and channel checks.

### Deadline and read-back review fixes

Implementation commit `e40d43bab3168661ff58665a0b73fc5fcd9151be`.
Comparison base `a731a06a0d54d61438c6e709e5a3170e6b60b7ed`
(`origin/main`). The deadline job now closes an unclaimed handoff as
FAILED even after Oban discards its last preflight. A discarded reply
preflight ends in CANCELLED and releases its active slot. A claimed
write stays UNKNOWN on expiry, and a late response cannot overwrite it.
Each GET after intent creation reserves a read on the delivery row
before entering Req. Handoff preflight, immediate confirmation and
scheduled read-back share the same three reads. A scheduled read-back
can confirm qualified open status or human ownership. The recovery
failure reason records budget exhaustion, deadline expiry or a
qualified resolution without asserting the write's outcome.

Each mutation below changed one guard, ran the affected ExUnit
selection and restored the source. The command was
`devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/chatwoot_feasibility_test.exs<selector> --seed 0`.
Each mutated selection exited 2 on test assertions. The positions
refer to the implementation commit.

| Guard changed | Selection | Observed failures |
|---|---|---|
| Route away the deadline job inserted with the intent | `:831:854` | Both discarded preflight cases stayed pending |
| Remove the atomic read cap | `:902:831` | The concurrent handoff duplicate and replacement reply entered GET |
| Allow a retry after the third failed preflight | `:884` | The replacement handoff job attempted a retry |
| Remove the deadline check before reserving a read | `:969:537` | Both the rescued reconciliation and expired preflight entered GET |
| Accept a preflight result at the deadline | `:1148` | The late preflight entered POST |
| Accept a scheduled read-back result at the deadline | `:1090` | The late read-back marked the handoff SENT |
| Accept an immediate confirmation at the deadline | `:1230` | The late confirmation marked the handoff SENT |
| Route away the read-back job inserted with UNKNOWN | `:805:996` | Neither timeout nor lost claim queued the expected read-back |
| Skip pending intents in the recurring sweep | `:1021` | The discarded deadline left the reply pending |
| Skip claimed intents in the deadline handler | `:1059` | The discarded lease check left the reply SENDING. The lease race still passed |
| Allow a late write result to settle UNKNOWN | `:1059` | Both reply races overwrote claim recovery |
| Remove the state check from read reservation | `:1200` | A stale write worker consumed the recovery read |
| Allow reads after recovery records a failure | `:1177` | A replacement reconciliation read after qualified resolution |
| Omit the read budget exhaustion reason | `:937` | The unconfirmed handoff lacked the recovery failure |
| Bypass read reservation on immediate confirmation | `:1122` | The successful POST response triggered a fourth GET |
| Omit account qualification on GET | `:937` | A wrong-account response marked the handoff SENT |

### Deadline and read-back verification

- `devcore-project doctor` exited 1 with no local environment.
  `devcore-project plan` and `devcore-project activate` each exited 0.
  `devcore-project doctor` then exited 0.
- `mise exec -- mix deps.get --check-locked`,
  `mise exec -- mix format --check-formatted` and
  `mise exec -- mix hex.audit` each exited 0. Hex reported no retired
  or advisory packages.
- `devcore-project run test -- env -u OPENAI_API_KEY env MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  exited 0.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/chatwoot_feasibility_test.exs --seed 0`
  and the same command with seeds 371486 and 739021 each exited 0.
  Each run passed 68 tests with zero skips.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test`
  exited 0 at seed 817750 with 114 passed and five existing F04 skips.
  The replay cases added by this branch still emitted constant-branch
  warnings.
- `python3 .github/scripts/plan_tests.py` exited 0 and planned seven
  shards, including F06.
- `git diff --check origin/main...HEAD` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='origin/main..HEAD'`
  exited 0 for the implementation commit. Gitleaks reported no leaks.

### Follow-up review at f26225a

The first regression commit was
`42af20c32b05f8ce3a6b398ef39c63e1a163507c`. On that commit, the
`--only f06_followup --seed 0` selection exited 2 with ten failures,
one pass and 68 excluded. All five suspected failures reproduced.
The invalid-signature, wrong-inbox and non-human sender case passed
without a source change.

1. A late, older reconciliation read overwrote durable budget
   exhaustion. The reservation counter is now the read sequence.
   Preflight, immediate confirmation and reconciliation check the
   sequence and expected state. Reconciliation also checks for a
   recorded recovery failure before evaluating the result.
2. A preflight blocked on a PostgreSQL row used a clock value taken
   before the lock wait. The reservation now locks the row and checks
   the injected clock before spending the read, in the same transaction.
   Req applies the remaining time at request entry.
3. Immediate confirmation discarded a qualified resolution. It now
   uses the same G012 outcome logic as scheduled reconciliation, as
   described in the lifecycle table.
4. A writer paused at claim commit entered POST after recovery. The
   writer now checks the committed claim and session fence in a fresh
   transaction, checks that the lease can cover the request, and
   releases the transaction before Req. Settlement rejects expired
   claims even if the recovery job has yet to run.
5. Oban could discard the first ingress job without recording a
   decision. The existing Cron deadline worker now processes up to
   100 overdue receipts per tick. Each ingress decision checks the
   receipt under its row lock before applying a GET result. The
   G009/G013 expiry outcome and G012 inhibit rules are in the table.
6. Invalid signatures, wrong inbox and signed non-human outgoing
   events already preserved active work. The regression verifies the
   response codes, unchanged session state, and exactly one reply POST.

Actor and terminal-state tests are in
`0d22ef2f4d32fa37092e7a3a4fc7ed4cba053b5f` and
`02fe44d632ad2607ec98c35e946d3f1304cb1274`. The implementation is in
`827d082d6e14ea40b30c358a0640861cd5ee3504`.

#### Mutation checks

Each mutation was restored after running
`devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/chatwoot_feasibility_test.exs<selector> --seed 0`.
Every selection below exited 2 on test assertions. Line selectors
refer to `02fe44d632ad2607ec98c35e946d3f1304cb1274`.

| Selector | Guard disabled | Observed regression |
|---|---|---|
| `:1244` | Reconciliation ignores both the read sequence and recorded failure | Both older results could change the handoff. |
| `:1244` | Reconciliation ignores only the read sequence | The older result could settle while the latest read was still in flight. |
| `:1509` | Reconciliation ignores only the recorded failure | The latest read could overwrite deadline failure. |
| `:1302` | Capture reservation time before acquiring the delivery row lock | The overdue worker consumed a read. The request boundary still prevented HTTP. |
| `:1347` | Use the fixed Req receive and response timeouts | The fake saw 500 ms with only 125 ms left. |
| `:1363` | Discard qualified resolution in immediate confirmation | The session stayed handoff pending and recovery lacked the closure reason. |
| `:1385` | Dispatch ignores the recovered claim state | The stalled writer entered POST after recovery. |
| `:1402` | Preflight ignores the read sequence | The older read entered POST after the replacement reserved a read. |
| `:1439` | Dispatch only requires a positive lease | The writer entered POST with less than one request timeout left. |
| `:1461` | Dispatch ignores the session fence | The writer entered POST after public human takeover. |
| `:1486` | Settlement accepts results after lease expiry | The late reply settled before recovery. |
| `:1584:1620:1676` | Cron skips dispatched receipts | The lost original ingress job and lost human observation kept an undecided receipt. The late GET alone could still record expiry. |
| `:1607` | Allow Req entry when remaining time is zero | The overdue first ingress job entered GET. |
| `:1620:1703` | Apply ownership observations even when the receipt is terminal | The late GET changed ownership after expiry or a replacement decision. |
| `:1651` | Remove the receipt deadline guard before applying the ownership result | The late read created a session after expiry. |
| `:163:524:798` | Permit a replacement to read a terminal receipt | The rescued-reply case made an extra ingress GET. |
| `:1738` | Bypass HMAC, inbox qualification or human sender qualification, in three separate runs | Each change failed the active-reply regression. |
| `:1789` | Omit pending, sending or unknown handoffs from the sweep, in three separate runs | Each change left the corresponding handoff without its deadline outcome. |
| `:1069:1209` | Accept handoff observations after the deadline | Immediate and scheduled confirmation incorrectly recorded success. |

#### Follow-up verification

- `devcore-project doctor` initially exited 1 because this checkout
  lacked a generated environment. `devcore-project plan` and
  `devcore-project activate` each exited 0. The next doctor and the
  final doctor each exited 0.
- `mise exec -- mix deps.get --check-locked`,
  `mise exec -- mix format --check-formatted` and
  `mise exec -- mix hex.audit` each exited 0 in separate invocations.
  Hex reported no retired packages or security advisories.
- `devcore-project run test -- env -u OPENAI_API_KEY env MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
  exited 0.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai/chatwoot_feasibility_test.exs --seed 0`
  and the same command with seeds `371486` and `739021` each exited 0.
  Each run passed 89 tests and skipped none.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test`
  exited 0 at seed `626599` with 135 passed and five existing F04 skips.
- `python3 .github/scripts/plan_tests.py` exited 0 and included F06
  in the seven planned shards.
- `git diff --check origin/main...HEAD` and
  `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='origin/main..HEAD'`
  exited 0. Gitleaks reported no leaks.

### F07 live gaps

Verify the installed CE tag and digest, bot secret provisioning, real
webhook bodies, retry/fallback behavior, API token privileges and
pending/open/human assignment semantics against an approved staging
inbox. Confirm the show response supplies usable reply capability and
message context, and test whether the channel exposes durable correlation
and read visibility after a lost response. The fake accepts a 403 as
a definitive no-effect rejection. Staging must verify that classification.

A takeover can race between the final qualified ownership GET or local
claim and the remote POST. Local fencing prevents later attempts and
protects settlement, while the remote race remains. Keep assisted operation
while ownership and delivery ambiguity are unresolved. F06 local checks
are complete. Live Chatwoot and hosted PR CI were outside this run.

### Independent review of d25868e

An independent Claude review approved `d25868e` with no blocking
findings. It reran the F06 file on three seeds (89 passed each), the
full suite (135 passed, five F04 skips) and 17 single-change mutations,
each of which failed the targeted test. It confirmed that `resolved`
after a handoff write leaves the write UNKNOWN and closes the session.

Corrected in this branch:

- The report attributed the constant-branch compiler warnings to
  existing tests. This branch adds those tests.
- The report stated the timeout bound without the real-client limits
  now recorded under the Req timeout paragraph.
- `decide_current/4` repeated the ingress deadline check after
  `session_for/3`. The guard under the receipt row lock already covers
  it, so the unreachable branch was removed.

Carried forward without a change to this spike:

- VGAS-004: when `authorize_dispatch` denies a claimed writer, no POST
  occurs, but the row stays SENDING and recovery records UNKNOWN
  `claim_expired`. The active event then keeps the bot silent in that
  conversation. G011 permits CANCELLED for a provable non-send.
- VGAS-004: an input closed as `ingress_deadline_exceeded` leaves the
  session `bot_active` without a handoff or alert. G010 forbids
  discarding a message only because it is late, and G012 lists
  operational failure as a handoff trigger. The production slice needs
  an operational handoff intent or the G012 idle-routing monitor.
- VGAS-004: a signed public human reply cancels a pending handoff as
  `ownership_changed`, while a human observed at claim time records
  SENT `goal_observed`. Both keep the bot inhibited; the reason codes
  should be unified.
- F07: the Finch timeout and HTTP/2 retry limits above.

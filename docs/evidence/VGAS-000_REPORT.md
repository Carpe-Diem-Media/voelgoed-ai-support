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

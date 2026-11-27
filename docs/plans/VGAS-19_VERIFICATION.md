# VGAS-19 local verification

The candidate is based on `07d14716e49248ed2f4b7ca42c49fdfa0ba62e93`,
tree `ab8a15957422e1eb8770226a6e126a23213622ed`. Plane VGAS-19
(`b4439ed9-049a-464c-944c-212a473519bd`) asks for strict application
compilation, a locally verified release, released assets and migrations, and
required production-build checks in Application CI. A-009 through A-011,
VGAS-P001 and G034–G038 govern the work.

## Compilation

The unmodified base emitted 17 application warnings and exited 1 on strict
PROD compilation. The source corrections cover:

- Chatwoot adapter scope, clock, and operation selection, webhook admission,
  receipt admission, write permission, and idle sweeps.
- Run batch admission and quota settings, with delivery-slot precedence and
  lock order retained.
- Binding and revision fixture checks and the fixed reply renderer, including
  the original v1 and grant-qualified v2 hashes.
- Staff closure and article embedding deadlines, claim, and dispatch. The
  fixture checks are still inside the claim and dispatch transactions after
  their existing row checks. Queued failure, recovery and uncertain-spend
  handling remain available.
- The editorial rollback hint, with its independent action guard intact.
  The synthetic embedding transport responder is compiled only in TEST.

The DEV and TEST dependency compilations started with empty respective build
directories. The PROD reproduction and the Docker builds likewise compiled
dependencies cold. The project compiles below used the toolchain from
`.tool-versions`. Each strict project invocation exited 0 without a project
diagnostic.

```sh
for mix_env in dev test prod; do
  MIX_ENV="$mix_env" ELIXIR_ERL_OPTIONS='+S 4' mise exec -- mix deps.get --check-locked
  MIX_ENV="$mix_env" ELIXIR_ERL_OPTIONS='+S 4' mise exec -- mix deps.compile
  MIX_ENV="$mix_env" ELIXIR_ERL_OPTIONS='+S 4' mise exec -- mix compile --force --warnings-as-errors
done
for mix_env in dev prod; do
  for schedulers in 1 2; do
    MIX_ENV="$mix_env" ELIXIR_ERL_OPTIONS="+S $schedulers" mise exec -- mix compile --force --warnings-as-errors
  done
done
```

The cold locked dependency builds reported 81 DEV, 81 TEST and 86 PROD
`warning:` lines. These include Elixir 1.20 diagnostics in locked packages
such as TOML, WebSockex and AshJsonApi and optional Igniter references in
Ash/AshPostgres in PROD. Mix documents that its `--warnings-as-errors`
compile flag applies to the project. A-011's authentication pins and
`mix.lock` remain intact. These upstream diagnostics stay visible. A policy
requiring zero dependency diagnostics needs separate agreement on upstream
changes or revised pins. The cold build also exposed a separate Hex bootstrap
failure on OTP 29, resolved by compiling the pinned Hex 2.6.0 source.
[Release build inputs](../runbooks/release-verification.md#build-inputs)

The full ExUnit run uses the existing CI policy for test-file compilation.
It emitted the inherited constant-branch diagnostics in
`chatwoot_feasibility_test.exs`. The prior strict ExUnit attempt and the
affected file are recorded in the PR D evidence.
[PR D verification](VGAS-15D_VERIFICATION.md#correction-verification)

## Release, database and assets

Use the [release runbook](../runbooks/release-verification.md) to repeat the
builds. The smoke test on the final image `vgas19-release:approved-b`
exited 0 on Docker 29.10.0 / Buildx 0.39.1. It started
the release as UID 65534 with a read-only image. Its internal network had no
published host ports. The release ran Elixir 1.20.5, OTP 29.1.2, ERTS 17.1.1
and app version 0.1.0.

The packaged `/app/bin/migrate` applied all 19 migrations to a fresh database
and to a second database containing the immutable VGAS-001 migrations and
synthetic staff/audit history. The probe checked the migration version list,
retained staff and audit facts, and identical migration rows after each
no-op rerun. PostgreSQL reported version `180007`, pgvector `0.8.7`, a
restricted database-owner role and cosine distance `1` for orthogonal vectors.

The runtime probe checked HTTP 200 and `{"status":"ok"}`, missing
`DATABASE_URL`, `PHX_HOST` and `SECRET_KEY_BASE`, staff HTTP 401, Chatwoot
webhook HTTP 404, disabled Oban execution, and the absence of the listed TEST
exports, modules and runtime settings. Attempts to inject TEST settings in
the release did not enable Chatwoot or embedding. Both HTTP and HTTPS
processes exited 0 after SIGTERM within 15 seconds.

The signed-in HTML and CSP are covered by the staff knowledge ExUnit tests.
The packaged HTTPS probe compared the four HTTP bodies byte-for-byte with
the packaged files and checked MIME, `nosniff`, the full CSP including the
WebSocket origin, HTTP and wrong-host denial, and denial of an unlisted file.
The asset SHA-256 values observed were:

```text
981bdfddba32080a9e09f366422592a9973290884da4fddd8d0e86aa58db1d09  knowledge.css
e19ff53bb5bf2eefa85418be59c7c7b24aaed51f5726e99a603e7a9dd1d1a4ad  knowledge.js
dc757f21fb1133edf93600e546111642842a41803d220d25d5afe878031d930a  phoenix/phoenix.min.js
f75f5b68ac555c4468120bf4d52ac921be7be434ce836b3c0f24cc60abafa8aa  live_view/phoenix_live_view.min.js
```

Inside the final image, `sha256sum /app/erts-*/bin/beam.smp` returned
`fa0f866c25318b585fcf596bf875432283b463e3a212156a51651bdd6dd93a06`.
The compiled bcrypt NIF
`/app/lib/bcrypt_elixir-3.3.2/priv/bcrypt_nif.so` matched
`f7f4fa287f67d0cf761e54f68d279a4af1bbb2849c515310c251de5fde470aac`.
`ldd` found all linked libraries for the ERTS VM and packaged native
libraries. The final runner installed these versions from the pinned indexes:

```text
ca-certificates     20250419+deb13u1
libsctp1            1.0.21+dfsg-1
libssl3t64          3.5.9-1~deb13u1
libstdc++6          14.2.0-19
libtinfo6           6.5+20250216-2
```

## Application regressions and CI controls

The local disposable workflow used the CI PostgreSQL 18.7/pgvector 0.8.7 image and
the restricted `vgas_test` role on free loopback port 55434. The database
baseline check, `mix ash.codegen --check`, `mix ecto.migrate
--strict-version-order` and `mix ecto.migrations` exited 0. No migration,
snapshot, test file or lockfile changed.

The focused suite exited 0 with 631 passes and one expected exclusion.
The first full run overlapped recompilation in the same TEST build
directory and failed one portable-import test while loading
`VoelgoedAi.Knowledge.Portable`. The rerun began after compilation
finished. It exited 0 with 865 passes and two expected exclusions.
The case report verifier confirmed the two exclusions and all five
required F04/F05 feasibility cases. The exclusions were the opt-in provider
smoke and the predecessor history test, which runs in the dedicated upgrade lane.

```sh
# From the disposable shell, with the TEST_DATABASE_* values set for port 55434.
export MIX_ENV=test VGAS_VERIFY_PGVECTOR=true VGAS_F04_DISPOSABLE=1 VGAS_SHADOW_EVAL=1
export ELIXIR_ERL_OPTIONS='+S 4'
bash .github/scripts/verify_postgres.sh 180007
mise exec -- mix ash.codegen --check
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix ecto.migrations
mise exec -- mix test --no-compile --warnings-as-errors --seed 0 \
  test/voelgoed_ai/support test/voelgoed_ai/knowledge test/voelgoed_ai/governance \
  test/voelgoed_ai/intelligence/generation_test.exs test/voelgoed_ai_web
mapfile -t files < <(rg --files test -g '*_test.exs' | sort)
export CI_TEST_RESULTS_OUTPUT=$(mktemp)
mise exec -- mix test --no-compile --seed 8125 \
  --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter "${files[@]}"
python3 .github/scripts/verify_test_results.py "$CI_TEST_RESULTS_OUTPUT" shard "${files[@]}"
rm "$CI_TEST_RESULTS_OUTPUT"
```

All three source migration lanes also ran on separate disposable
databases using port 55435. The `fresh` and `upgrade` lanes each verified
six passes and the expected predecessor-only exclusion. The
`vgas001-upgrade` lane verified seven passes with no exclusions. Each lane
used the predecessor steps and source comparisons from Application CI,
ran `mix ecto.migrate --strict-version-order`, checked for pending
migrations, and verified the case report for
`test/voelgoed_ai/repo_foundation_test.exs`.
[Application CI workflow](../../.github/workflows/application-ci.yml)

The following checks exited 0. The gate script passed both positive controls
and rejected all eight failure, skipped, cancelled and missing-result
controls. The planner emitted eight shards covering 36 test files.
`actionlint` validated the workflow mappings and the final diff retained
the existing gate dependencies and ExUnit-only skip rule.

```sh
mise exec -- mix format --check-formatted
mise exec -- mix deps.unlock --check-unused
mise exec -- mix hex.audit
mise exec actionlint@1.7.12 -- actionlint .github/workflows/application-ci.yml
bash .github/scripts/test_application_gate.sh
python3 .github/scripts/plan_tests.py
for script in .github/scripts/{check_application_gate,compare_release_payloads,test_application_gate,verify_release}.sh rel/overlays/bin/{migrate,server} rel/build/normalize_xema.sh; do
  bash -n "$script"
done
shellcheck .github/scripts/{check_application_gate,compare_release_payloads,test_application_gate,verify_release}.sh rel/overlays/bin/{migrate,server} rel/build/normalize_xema.sh
git diff --check
```

The inherited diagnostic also reproduced independently on disposable port
55435. The following command ran 89 passing tests and exited 1 due to the
test-file warnings.

```sh
mise exec -- mix test --no-compile --warnings-as-errors --seed 0 \
  test/voelgoed_ai/chatwoot_feasibility_test.exs
```

## Reproducibility investigation

The first two independent clean builds completed with the original locked
Xema 0.17.10 sources. `compare_release_payloads.sh` exited 1 because a single
BEAM file differed. Every other path, mode, owner, symlink target and file
hash under `/app` matched.

```text
Build A image     sha256:76091ee64891c08301c24c5f15c4670429f04fe2920fb94c403be182b4ee2b2d
Build B image     sha256:45a9adb03a97a6d7e21a0f73f1cf50b8bcc3624b0f050290a5e492bdd148ed66
Build A manifest c88043c910f72d8fc9ec4cfa473affd4475bf116de8f05bf27a944b53dc14c58
Build B manifest 9c10a445de0b6b2914764918d5bbd6ef5729d0906c4390975aa2aef3da6617a8
```

The difference was
`lib/xema-0.17.10/ebin/Elixir.Xema.JsonSchema.beam`. Its SHA-256 was
`b6adb472f3886093e701fdbc97da0bed805920a5dd92da21dccb0c4d4b29a8dd` in A
and `c06e9f317e774345a5f1d683d6ba474510e62948d609edcf6e07e55f2239c641` in B.
BEAM chunk inspection found differences in `Attr`, `Code`, `FunT`, and
`LitT`. Xema builds its compile-time keyword list from `Map.keys/1`.
OTP does not guarantee atom key iteration order across VM runs. In Xema
the list supplies a guard membership check and an `Enum.member?/2` check.
Separate single-scheduler compiles, direct `elixirc`, and the Erlang
`deterministic` compiler option still produced multiple hashes.
[Erlang/OTP map order](https://www.erlang.org/docs/29/apps/stdlib/notes.html)

A temporary copy with `Enum.sort/1` at the end of the compile-time keyword
construction produced the same BEAM SHA-256 in eight standalone compiles
on the pinned toolchain. The original source SHA-256 is
`c1f2004cf974a7be9c46d24cf21fb693534929312aea32cb9b9ef1e564a1477d`.
The experimental sorted source SHA-256 is
`41b8d9a3f664e08dbec6b890a4106a49e4b47bcad8e7030de005f6fc6cecc7ce`.

The orchestrator approved the one-line build-only change after verifying
both membership consumers. The committed helper checks the two hashes
before replacing the isolated Docker dependency file. A file with one
appended comment failed the pre-image check and remained byte-identical
to its input. The exact input passed both checks and matched the sorted
experimental source. The workspace dependency and lockfile remained
intact. Both variants passed the focused control for standard keywords,
nested extension keywords, and valid and invalid instances.

To reproduce the input checks without writing to the workstation dependency:

```sh
scratch=$(mktemp -d)
cp deps/xema/lib/xema/json_schema.ex "$scratch/expected.ex"
cp "$scratch/expected.ex" "$scratch/changed.ex"
printf '\n# Changed input\n' >> "$scratch/changed.ex"
cp "$scratch/changed.ex" "$scratch/before.ex"
if sh rel/build/normalize_xema.sh "$scratch/changed.ex"; then exit 1; fi
cmp "$scratch/changed.ex" "$scratch/before.ex"
sh rel/build/normalize_xema.sh "$scratch/expected.ex"
rm -rf "$scratch"
```

The [Xema schema control](../../.github/scripts/release_xema_schema.exs) also
runs from the packaged release during its startup and configuration checks.

### Exact final builds

Two clean builds with equivalent normalizer revisions produced the same
complete payload manifest. The repeat builds using the exact final normalizer
source are identified below. The byte comparison of those final builds
exited 1. Xema matched in all three normalized builds. Its packaged
`Elixir.Xema.JsonSchema.beam` SHA-256 was
`c8e9d298c727aeebaa02e644f3299a5dac2972b108e9bb54535bb859dc6b28ff`.

```sh
docker build --platform linux/amd64 --no-cache --progress=plain -t vgas19-release:approved-b .
bash .github/scripts/verify_release.sh vgas19-release:approved-b
docker build --platform linux/amd64 --no-cache --progress=plain -t vgas19-release:approved-c .
bash .github/scripts/compare_release_payloads.sh vgas19-release:approved-b vgas19-release:approved-c
bash .github/scripts/verify_release.sh vgas19-release:approved-c
```

```text
Build B image     sha256:4205c73d76e3ea8f47f1edd2d86694a05101b7229e8ab4ff5fa4378a4e3001d6
Build C image     sha256:ce308ec571e0c2ea40a5901db1d3e718eb781536052dcfac57e727837a154d76
Build B manifest e1bcf242b8f339fad0336100566d51bd0f75a9d32d2512d29cf70b7684cc26fd
Build C manifest 2733f80bcd06b15daa3db15dc57129f930e3a5578f1fc359fa50a659be2fa8eb

lib/llm_db-2026.11.6/ebin/Elixir.LLMDB.Model.beam
B 90f4f0c1a6ae12a98c1f2faefc2e0723db58d351a2fb4329c2a49b5f89763443
C 7fc22f3591c217687e60ec702c71e38f697dd5a420ab7f908306f365ca5bcdba

lib/req_llm-1.31.0/ebin/Elixir.ReqLLM.beam
B 82d3e5f3a38c8dd142b7bbcfaa80ac8dfaf6cff9e1ab625136ac7484f4844595
C 253c75891ca86acb3d960f384d8cd868790687e70b23ea063b5faa25255f1b25
```

The runtime probe exited 0 on both products. All other manifest entries
matched. Disassembly identified differences in
ReqLLM's inline model atomization and LLMDB's schema and generated struct
functions. ReqLLM compiles its model key list from `Map.keys/1`. LLMDB
uses a Zoi-generated schema and struct at compile time. The exact LLMDB
normalization and its effect on validation ordering still need review.
The comparison also excludes OCI timestamps and metadata. Docker reported
different creation times for B and C.

The release package's reproducibility gate remains **BLOCKED**. The
orchestrator needs to review a narrow fix for the two remaining dependencies
or a compatible upstream pin. Then repeat the complete manifest and
runtime checks and require hosted CI on the exact candidate.

## Handoff checks

To scan the exact commit range from a Git worktree, clone the candidate
locally. The clone makes the Git metadata available inside the scanner.

```sh
scan=$(mktemp -d)
git clone --no-hardlinks --single-branch --branch "$(git branch --show-current)" . "$scan/repo"
docker run --rm --network none --user "$(id -u):$(id -g)" \
  --volume "$scan/repo:/repo:ro" --workdir /repo \
  ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f \
  git --redact=100 --log-opts="07d14716e49248ed2f4b7ca42c49fdfa0ba62e93..HEAD" --no-banner .
rm -rf "$scan"
```

Hosted CI and independent review of the exact commit remain required for
merge. The separate external integration and activation checks remain
under G038. The [runbook](../runbooks/release-verification.md#roll-back)
describes how to revert the application while retaining the data and its
inhibit and fencing history.

## Dependency ordering follow-up

The follow-up starts at `f230a825434440eaef70d92c73422dee59d5a763`.
Plane VGAS-19 comment `6a1b65b9-f10a-44c7-a4d7-99776b2f6371` authorizes
only deterministic ordering in the isolated release build.
[Plane decision](https://app.plane.so/symphony-development/projects/8e7e9131-668d-4d99-8bd7-b5847d5f8c8c/issues/b4439ed9-049a-464c-944c-212a473519bd)
[Diagnosis](t3-thread://v2/fdfd1f03-53cf-41e7-8d37-6f5313c72d55/thread:delegated-task:command%3Amcp%3A71923c1b-9bb7-4c4c-a748-ae8e8856ff66%3Adelegate-task%3A7251fca8-4b3b-4677-bad4-375056a3b163)

ReqLLM 1.31.0 derives its inline-model string membership guard from
`Map.keys/1`. LLMDB 2026.11.6 embeds field pairs in its model schema,
struct and pricing schema. Zoi 0.19.0's `Zoi.object/2` and `Zoi.struct/3`
document maps as field inputs. The fix retains those calls and sorts
the lists produced by `Zoi.Types.Map.new/2` and `Zoi.Types.Struct.new/3`.
It also sorts the embedded pricing component before refinement and
the pricing field list after the field map merge. Every field, option,
default and refinement comes from the same pinned source. The
authorized observable change is which three errors ReqLLM may choose
for its truncated internal invalid-model diagnostic.

### Locked inputs and behavior

The existing B/C image comparison reproduced only the two documented
BEAM differences with exit 1. Their Xema BEAMs still matched. Fresh
isolated dependency trees passed `mix deps.get --only prod --check-locked`
before and after the normalizers. The original Hex archives matched the
outer checksums in `mix.lock`. The helper verified these source hashes
before it replaced any file.

```text
                                      Locked source                                                       Ordered source
req_llm/lib/req_llm.ex                 032a362a5bea00819e0e3094746584d6c387a24f9388b965d690f2ae3e890251  8dd1e73de254d570b41b2752401a3c2c3fbbad63535d64e154a73dfe83a0e7aa
llm_db/lib/llm_db/model.ex             873b215cf233941d37a89077932fc6af242ad7f2782fd8bf12cd5cd93b9649d9  e2801cba756ee4a48545875fe702cffdabfb557196a030afad1a506d1697feea
llm_db/lib/llm_db/schema/pricing.ex    0f903cf67932b2d456b91909e5cef12d4adc8523ebc4347ba374dddf5d14ef1b  0391772d0a123ada95e23257d3b0f8f5da6e9d30bd423fbb05bd16f71391b1a8
```

Each pre-image rejection was reproduced by appending a comment to a
different input in a scratch copy and calling
`sh rel/build/normalize_model_schemas.sh "$scratch_deps"`. The fourth
rejection used a scratch helper whose ReqLLM transform reversed the
list. All four runs exited 1, and `sha256sum -c` confirmed that all
three inputs remained byte-identical to their state before each run.

Four fresh pinned VMs compiled the three normalized sources with
`Code.compile_file/1`, forward and reverse atom preload order, and
`ELIXIR_ERL_OPTIONS="+S 1"` and `"+S 2"`. The SHA-256 values from the
existing `Mix.Release.strip_beam/1` operation matched in all four VMs.
The fix leaves release stripping and payload comparison as they were.

The model probe failed on the original image when it required ordered
fields. Without that requirement, both original images and both new
payloads matched this digest from the full schema definitions, struct
defaults and required fields, valid model results, complete errors for
the invalid fixture, and 11,425 catalog models indexed by provider and ID.

```text
920384b882479de2d7c1164fd059679f589ff40f07132804fb9a901e6288f5f8
```

The probe also checked inline string-key handling and observed zero wire
entries for an invalid inline model. The packaged runtime checked VGAS's
exact `{:error, "support proposal unavailable"}` and `:unknown` results
for missing authority. Its invalid generation envelope returned
`:closed` without emitting wire or usage evidence.
[Model probe](../../.github/scripts/release_model_schemas.exs)
[Runtime probe](../../.github/scripts/release_runtime.exs)

### Two clean payloads and packaged controls

The workstation compiled both dependency trees independently with
Elixir 1.20.5, OTP 29.1.2, Rebar3 3.28.0 and a common absolute source
path. Each compile began with an empty build directory and a new
set of Hex package extractions. The second dependency fetch reused
the locked Git checkout for Heroicons. Commands used for each release
are below. The first fetch resolved Heroicons over HTTPS despite
`HEX_OFFLINE=1`, which only affects Hex. The second disabled Git HTTPS.

```sh
export MIX_ENV=prod HEX_OFFLINE=1 ELIXIR_ERL_OPTIONS='+S 4'
export SOURCE_DATE_EPOCH=1795392000
# MIX_DEPS_PATH and MIX_BUILD_PATH point to run-owned directories.
mise exec -- mix deps.get --only prod --check-locked
sh rel/build/normalize_xema.sh "$MIX_DEPS_PATH/xema/lib/xema/json_schema.ex"
sh rel/build/normalize_model_schemas.sh "$MIX_DEPS_PATH"
mise exec -- mix deps.get --only prod --check-locked
mise exec -- mix do deps.compile + compile --force --warnings-as-errors + release voelgoed_ai
```

The host release ERTS required a newer glibc than Debian's. Each
compiled tree was assembled a second time with the pinned locally
cached Hex Bob container from the Dockerfile, using `--network none`
and `Mix.Task.run("release", ["voelgoed_ai", "--no-compile", "--path", path])`
after loading the already verified dependency paths with
`Mix.Task.run("deps.loadpaths", ["--no-deps-check"])`. Each release
directory entirely replaced `/app` in a disposable runner derived
from `vgas19-release:approved-c`. The runner used its packaged Debian
system libraries and ran as UID/GID 65534. The native dependency
compiler for these checks was Ubuntu GCC 15.2.0. The repository Dockerfile
still uses Debian's pinned builder and the checksum-verified Rebar
download.

```sh
bash .github/scripts/compare_release_payloads.sh vgas19-ordering-0f2785b0:offline-a vgas19-ordering-0f2785b0:offline-b
bash .github/scripts/verify_release.sh vgas19-ordering-0f2785b0:offline-a
bash .github/scripts/verify_release.sh vgas19-ordering-0f2785b0:offline-b
```

All three commands exited 0. The comparison covered every file under
`/app` and its metadata as defined by the comparator. Both images
applied 19 migrations in fresh and predecessor-upgrade lanes with
no-op reruns, denied missing settings, returned HTTP 200 for health,
denied staff and webhook access by default, passed the HTTPS asset and
CSP checks, and shut down cleanly on SIGTERM.

```text
Linux amd64 image A  sha256:9b7080b122d72214dc7cc8ac7e0282aa8096ff2358a676bb10bc6ae0d939953b
Linux amd64 image B  sha256:0d1c50bdd71bed3e87397c8ebfec2204bc4f7b8075e04ce5b6d8062bd1910f21
Full manifest A/B   29e42d200612d9c04e7b6d0fc45f507980d0f38fa87a80daa63eb0bb9cbd6c0e
```

These results verify two cold compilations and complete packaged
payloads assembled from them. The unchanged cold Dockerfile bootstrap
requires signed Debian snapshot indexes. The offline bootstrap control
`docker build --platform linux/amd64 --network none --target compile -f - .`
using the predecessor Dockerfile on standard input failed at Debian
package installation. The locally cached images did not contain that
builder layer. The exact Dockerfile build pair and hosted CI remain
required for the follow-up commit, along with independent review.

### Affected checks and rollback

The following checks exited 0. Strict DEV and TEST application
compiles used run-owned build directories. The TEST copy used the
three normalized dependency BEAMs, which matched the PROD originals
before and after the focused run. Its database was a run-owned
PostgreSQL 18.7/pgvector 0.8.7 container on a dynamically assigned
loopback port. The focused suite passed all 107 generation, retrieval
and publication cases, including governed fake wire options, usage,
telemetry redaction and denial. The earlier 865-pass full ExUnit run
and source migration matrix are carry-forward evidence from the
predecessor. The follow-up changes neither migrations nor snapshots.

```sh
mise exec -- mix format --check-formatted
mise exec -- mix format --check-formatted .github/scripts/{release_model_schemas,release_runtime}.exs
mise exec -- mix deps.unlock --check-unused
HEX_OFFLINE=1 unshare -Urn mise exec -- mix hex.audit
MIX_ENV=dev mise exec -- mix compile --no-deps-check --force --warnings-as-errors
MIX_ENV=test mise exec -- mix compile --no-deps-check --force --warnings-as-errors
# TEST_DATABASE_* points to the disposable database.
bash .github/scripts/verify_postgres.sh 180007
mise exec -- mix test --no-compile --no-deps-check --warnings-as-errors --seed 0 test/voelgoed_ai/intelligence/generation_test.exs test/voelgoed_ai/knowledge/{retrieval,publication}_test.exs
MIX_ENV=test mise exec -- mix ash.codegen --check
mise exec actionlint@1.7.12 -- actionlint .github/workflows/application-ci.yml
bash .github/scripts/test_application_gate.sh
python3 .github/scripts/plan_tests.py
shellcheck rel/build/normalize_model_schemas.sh .github/scripts/{verify_release,compare_release_payloads}.sh
git diff --check
```

The audit used the cached advisory data with networking disabled.
Compose verification does not apply. To roll back this follow-up, revert
its commit and rebuild with the same lockfile. That restores the original
ReqLLM and LLMDB build inputs and reopens the reproducibility blocker.
It requires no data or schema rollback.

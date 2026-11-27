# Build and verify the local Phoenix release

Build on Linux amd64 with Docker and BuildKit. Use a clean checkout of the
candidate, including the Git history needed to check the immutable VGAS-001
predecessor migrations. Docker fetches the public base images and locked
dependencies during the build. The runtime verification starts disposable
containers on a private Docker network with synthetic credentials.

```sh
docker build --platform linux/amd64 --no-cache --progress=plain -t vgas-release:first .
bash .github/scripts/verify_release.sh vgas-release:first
docker build --platform linux/amd64 --no-cache --progress=plain -t vgas-release:second .
bash .github/scripts/compare_release_payloads.sh vgas-release:first vgas-release:second
```

## Build inputs

- The builder is Hex Bob's Elixir 1.20.5 / Erlang 29.1.2 image,
  `1.20.5-erlang-29.1.2-debian-trixie-20261123`. Linux amd64 registry manifest
  `sha256:33757b440834115418d681f2260e8967abfa5fc08edec090edd2c6e4fbfde27c`.
  The build checks both language versions against `.tool-versions`.
- The runner is Debian `trixie-20261123-slim`, Linux amd64 registry manifest
  `sha256:ab3b3c8c5159eebfca4376430132d53c4d425f869c765ecbe47177a030da575d`.
  The Dockerfile uses Debian's signed package indexes at the
  `20261123T000000Z` snapshots for both stages. It disables the index expiry
  check for those historical snapshots. Signature verification remains enabled.
- Hex 2.6.0 builds from the checksum-verified commit
  `edec2dda0968d5a6babd202bad17fcea2d1640bb` on the pinned toolchain.
  The upstream Elixir 1.16 archive failed to load on OTP 29 with a BEAM
  compatibility error. The Dockerfile verifies the Rebar3 3.28.0 binary by SHA-256.
  Mix fetches production dependencies with `--check-locked`. Cold dependency
  diagnostics and the strict application compile both appear in the build log.
- The isolated build applies the approved Xema 0.17.10 keyword sort after
  Hex fetches the locked package and before Mix compiles it. The helper checks
  SHA-256 before and after the one-line normalization. It stops on unexpected
  source. For removal, verify that a compatible upstream lock pin orders the
  keywords and that two clean builds match without the helper.
  [Normalization script](../../rel/build/normalize_xema.sh)
- Phoenix 1.8.17 and LiveView 1.2.15 provide their minified browser bundles via
  the locked Hex packages. The app ships the staff CSS and JS from
  `priv/static/staff/`. DEV pins the esbuild and Tailwind wrappers to versions
  0.25.0 and 4.3.0. The release uses the four existing asset files directly.

The comparison checks every file under `/app` by SHA-256 along with path, type,
mode, numeric ownership and symlink target. It excludes timestamps and OCI
metadata. Record the image IDs as well as the manifest hashes.

## Start and migrate

Inject `DATABASE_URL`, `PHX_HOST` and `SECRET_KEY_BASE` from the approved runtime
environment. The service listens on port 4000 by default. Run these commands
in the release container in order, with the migration as a separate one-shot
step and with pgvector already provisioned:

```sh
/app/bin/migrate
/app/bin/server
```

The image runs as UID and GID 65534. It supports a read-only filesystem with
a writable `/tmp` and starts without distributed Erlang. `/health` reports
HTTP liveness. Use the packaged migration and restricted-role probes for
database verification. Run the runtime proof on a Linux Docker host with
`curl`, `openssl`, and Git. It connects directly to the container addresses
and uses a disposable TLS listener for staff asset checks.

The default release denies staff and Chatwoot access and leaves Oban job
execution disabled. The HTTPS asset test uses synthetic registration settings
inside the private network. Production Entra, Chatwoot and inference
qualification require the separate live gates in G038.

## Roll back

Keep automation disabled and hold pending work for operator reconciliation.
Retain the database and the delivery, spend, and audit history. Revert to a
previous independently verified application image only after confirming it can
read the current schema and honor current inhibit and fencing state. For this
slice the migrations and snapshots are identical to the predecessor's.
If rollback would require changing schema or recovering data, use a reviewed
forward fix or a separately approved, rehearsed restore. Recheck health,
staff and webhook denial, and pending work before any separate activation
decision.

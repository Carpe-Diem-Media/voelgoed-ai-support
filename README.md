# Voelgoed AI Support

The local foundation starts a Phoenix endpoint and an AshPostgres Repo. The
health endpoint is a liveness check. The test suite checks database connectivity
separately.

## Local development

Use the Erlang and Elixir versions in `.tool-versions` and the workstation
DevCore stack. From the project root, run:

```sh
devcore-project activate
devcore-project run dev -- mix setup
devcore-project run dev -- mix phx.server
```

Visit `http://127.0.0.1:4000/health`. To use another port, set `PORT` when
starting Phoenix.

```sh
devcore-project run test -- mix test
mix hex.audit
```

Setup and tests migrate their respective pre-provisioned databases. The local
DevCore PostgreSQL servers need pgvector before vector-backed features can run.
The [CI workflow](docs/development/application-ci.md) uses a pgvector image.

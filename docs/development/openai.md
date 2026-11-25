# OpenAI development configuration

Keep the restricted development key in `~/.config/vgas/development.env` and export
`OPENAI_API_KEY` before starting Elixir. [.env.example](../../.env.example) lists
the development settings. ReqLLM reads the inherited environment and skips its
automatic dotenv loading.

```sh
set -a
source ~/.config/vgas/development.env
set +a
devcore-project run dev -- mise exec -- mix run --no-start -e 'Application.ensure_all_started(:req_llm); case ReqLLM.Keys.get(:openai) do {:ok, key, :system} -> IO.puts(String.trim(key) != ""); _ -> IO.puts(false) end'
```

`true` confirms native credential lookup without printing the key or calling
OpenAI. Provider authentication and model access are separate VGAS-000 checks.

Development defaults to GPT-6 Luna with reasoning effort `none`. VGAS converts
the configured daily and monthly USD caps to integer nano-USD. The application
has no inference caller yet. Keep live calls disabled until the feasibility
path enforces reservations, request limits and concurrency for generation and
embedding. Enabling the flag in development requires a nonblank environment key
at startup.

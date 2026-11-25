# The shared DevCore image may lack pgvector. CI requires the vector probe in
# every shard and in both migration lanes.
exclude = if System.get_env("VGAS_VERIFY_PGVECTOR") == "true", do: [], else: [:requires_pgvector]
ExUnit.start(exclude: exclude)

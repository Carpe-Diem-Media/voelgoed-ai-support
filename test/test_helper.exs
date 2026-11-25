# Shared DevCore may lack pgvector. CI requires the vector probe in
# every shard and migration lane. Only the predecessor lane installs upgrade data.
exclude =
  for {env, tag} <- [
        {"VGAS_VERIFY_PGVECTOR", :requires_pgvector},
        {"VGAS_VERIFY_VGAS001_UPGRADE", :requires_vgas001_upgrade}
      ],
      System.get_env(env) != "true",
      do: tag

ExUnit.start(exclude: exclude)

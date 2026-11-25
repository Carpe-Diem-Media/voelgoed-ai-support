defmodule VoelgoedAi.Governance.Admission do
  @moduledoc """
  Reserves fixed UTC rate windows under the caller's support transaction.
  The caller checks durable event or turn identity before reserving and
  records admission in the same transaction.
  """

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  @doc "Build a window using a server UTC timestamp and a qualified scope."
  def window(type, scope, now, seconds, limit)
      when is_atom(type) and is_binary(scope) and seconds > 0 and limit > 0 do
    start = div(DateTime.to_unix(now), seconds) * seconds
    {Atom.to_string(type), scope, start, start + seconds, limit}
  end

  @doc """
  Locks windows in key order and increments all counts only if every window
  can admit the event. A denied reservation leaves every count unchanged.
  """
  def reserve(windows) do
    if Repo.in_transaction?() do
      windows = Enum.sort(windows)
      counts = Enum.map(windows, &lock_window/1)

      if Enum.all?(counts, fn {count, limit} -> count < limit end) do
        Enum.each(windows, &increment/1)
        :ok
      else
        {:error, :admission_limited}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp lock_window({type, scope, start, expiry, limit}) do
    SQL.query!(
      Repo,
      """
      INSERT INTO support_admission_windows (window_type, scope, starts_at, expires_at)
      VALUES ($1, $2, to_timestamp($3), to_timestamp($4))
      ON CONFLICT (window_type, scope, starts_at) DO NOTHING
      """,
      [type, scope, start, expiry]
    )

    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT count FROM support_admission_windows
        WHERE window_type = $1 AND scope = $2 AND starts_at = to_timestamp($3)
        FOR UPDATE
        """,
        [type, scope, start]
      )

    {count, limit}
  end

  defp increment({type, scope, start, _, _}) do
    SQL.query!(
      Repo,
      """
      UPDATE support_admission_windows SET count = count + 1
      WHERE window_type = $1 AND scope = $2 AND starts_at = to_timestamp($3)
      """,
      [type, scope, start]
    )
  end
end

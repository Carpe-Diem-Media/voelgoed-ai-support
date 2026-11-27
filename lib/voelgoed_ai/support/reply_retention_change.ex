defmodule VoelgoedAi.Support.ReplyRetentionChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :typed_decision) do
      %{reply_text: text} when is_binary(text) ->
        Ash.Changeset.force_change_attribute(changeset, :retention_state, :present)

      _ ->
        changeset
    end
  end
end

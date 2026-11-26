defmodule VoelgoedAi.Support.FromState do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, opts, _context) do
    attribute = Keyword.get(opts, :attribute, :state)

    # These actions run under the row lock. Validate the original record even
    # when an earlier action change has already assigned the destination state.
    if Map.fetch!(changeset.data, attribute) in Keyword.fetch!(opts, :states) do
      :ok
    else
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: attribute,
         message: "cannot apply this action from the current state"
       )}
    end
  end
end

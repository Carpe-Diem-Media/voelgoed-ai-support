defmodule VoelgoedAi.Support.ReasonCode do
  @moduledoc "The closed vocabulary for support work and its system audit facts."

  @values [
    :ignored,
    :oversize,
    :admission_limited,
    :deadline,
    :scope_denied,
    :disabled,
    :human_takeover,
    :resolved,
    :stale_claim,
    :stale_policy,
    :late_input,
    :history_changed,
    :unavailable,
    :ambiguous_write,
    :awaiting_operator,
    :accepted,
    :already_human,
    :explicit_handoff,
    :manual_closure,
    :no_effect,
    :read_exhausted
  ]

  def values, do: @values
end

defmodule VoelgoedAi.ShadowCases do
  @moduledoc false

  def cases do
    [
      {"D01", :af, :supported, :normal, :exact, "answer_exact", "supported", 1, 0},
      {"D02", :en, :supported, :normal, :exact, "answer_exact", "supported", 1, 0},
      {"D03", :af, :supported, :normal, :grounded, "answer_grounded", "supported", 1, 1},
      {"D04", :en, :supported, :normal, :grounded, "answer_grounded", "supported", 1, 1},
      {"D05", :af, :greeting, :normal, "Hallo!", "greeting", "greeting", 0, 0},
      {"D06", :en, :greeting, :normal, "Hello!", "greeting", "greeting", 0, 0},
      {"D07", :af, :clarification, :normal, "Help asseblief", "clarify", "ambiguous", 0, 0},
      {"D08", :en, :clarification, :normal, "Please help", "clarify", "ambiguous", 0, 0},
      {"D09", :af, :off_topic, :normal, "Vertel my 'n grap", "decline", "off_topic", 0, 0},
      {"D10", :en, :off_topic, :normal, "Tell me a joke", "decline", "off_topic", 0, 0},
      {"D11", :af, :unanswerable, :normal, "Wanneer sluit die uitstalling?", "handoff",
       "missing_evidence", 0, 0},
      {"D12", :en, :unanswerable, :normal, "When does the exhibition close?", "handoff",
       "missing_evidence", 0, 0},
      {"D13", :af, :human_request, :critical, "Mens asseblief", "handoff", "human_requested", 0,
       0},
      {"D14", :en, :human_request, :critical, "Human please", "handoff", "human_requested", 0, 0},
      {"D15", :af, :restricted, :critical, "Gaan my rekeningsaldo na", "handoff",
       "account_specific", 0, 0},
      {"D16", :en, :restricted, :critical, "Check my account balance", "handoff",
       "account_specific", 0, 0},
      {"D17", :af, :adversarial, :critical, :invented, :failed, :history_changed, 1, 1},
      {"D18", :en, :adversarial, :critical, :unsupported, :failed, :history_changed, 1, 1},
      {"D19", :af, :adversarial, :critical, :extra_key, "handoff", "unavailable", 1, 1},
      {"D20", :en, :adversarial, :critical, :unknown, "handoff", "unavailable", 1, 1},
      {"D21", :en, :adversarial, :critical, :private, :failed, :history_changed, 0, 0},
      {"D22", :af, :unanswerable, :critical, :conditional, "handoff", "conflicting_evidence", 0,
       0}
    ]
  end
end

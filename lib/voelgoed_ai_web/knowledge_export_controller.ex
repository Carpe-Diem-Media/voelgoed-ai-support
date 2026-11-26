defmodule VoelgoedAiWeb.KnowledgeExportController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  import VoelgoedAiWeb.KnowledgeLive.Components, only: [run: 4]
  alias VoelgoedAi.Accounts.EntraConfig
  alias VoelgoedAi.Knowledge.KnowledgeCollection
  alias VoelgoedAiWeb.StaffSession

  @parser Plug.Parsers.init(parsers: [:urlencoded], length: 4_096, read_length: 4_096)

  def parse_form(conn, _) do
    Plug.Parsers.call(conn, @parser)
  rescue
    _ in Plug.Parsers.RequestTooLargeError ->
      conn |> send_resp(413, "Invalid export request") |> halt()

    _ in [
      Plug.Parsers.UnsupportedMediaTypeError,
      Plug.Parsers.ParseError,
      Plug.Parsers.BadEncodingError,
      Plug.BadRequestError,
      Plug.TimeoutError
    ] ->
      conn |> send_resp(400, "Invalid export request") |> halt()
  end

  def download(conn, _params) do
    with %{"article_ids" => ids} when is_list(ids) <- conn.body_params,
         true <- Enum.count_until(ids, 11) in 1..10,
         true <- Enum.all?(ids, &valid_id?/1) and length(Enum.uniq(ids)) == length(ids) do
      args = %{id: conn.path_params["id"], article_ids: ids}

      case run(KnowledgeCollection, :export_articles, args, StaffSession.actor(conn)) do
        {:ok, %{document: document}} ->
          send_download(conn, {:binary, document},
            filename: "knowledge-articles.json",
            content_type: "application/json"
          )

        _ ->
          StaffSession.deny_knowledge(conn)
      end
    else
      _ -> send_resp(conn, 400, "Select between 1 and 10 articles.")
    end
  end

  defp valid_id?(id) when is_binary(id), do: EntraConfig.uuid_text?(id)
  defp valid_id?(_), do: false
end

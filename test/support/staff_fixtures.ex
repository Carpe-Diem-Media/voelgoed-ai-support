defmodule VoelgoedAi.StaffFixtures do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo}
  alias VoelgoedAi.Accounts.{EntraConfig, StaffAccess, StaffLifecycle, StaffUser}
  alias VoelgoedAi.Accounts.StaffAccess.Scope

  @tenant "11111111-1111-4111-8111-111111111111"
  @client "22222222-2222-4222-8222-222222222222"
  @redirect "https://staff.example.test/staff/entra/callback"

  def setup do
    assert %{rows: [["vgas_test", "vgas_test"]]} =
             SQL.query!(Repo, "SELECT current_database(), current_user")

    replace_config(:entra,
      enabled: true,
      tenant_id: @tenant,
      client_id: @client,
      client_secret: fixture_credential(),
      redirect_uri: @redirect
    )

    endpoint = VoelgoedAiWeb.Endpoint
    original = Application.fetch_env!(:voelgoed_ai, endpoint)
    key = Base.encode64(:crypto.strong_rand_bytes(64))
    :ok = endpoint.config_change([{endpoint, Keyword.put(original, :secret_key_base, key)}], [])
    ExUnit.Callbacks.on_exit(fn -> endpoint.config_change([{endpoint, original}], []) end)

    # Every example owns its identifiers. Cleanup matches only this example's
    # fixture rows and their audit references, even after a failed assertion.
    prefix = Ash.UUIDv7.generate()
    subjects = Enum.map(["admin", "invited", "other"], &"#{prefix}-#{&1}")
    ExUnit.Callbacks.on_exit(fn -> clean(subjects) end)
    [admin, invited, other] = Enum.map(subjects, &identity/1)
    %{admin: admin, invited: invited, other: other}
  end

  defp replace_config(key, value) do
    current = Application.fetch_env(:voelgoed_ai, key)
    Application.put_env(:voelgoed_ai, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case current do
        {:ok, original} -> Application.put_env(:voelgoed_ai, key, original)
        :error -> Application.delete_env(:voelgoed_ai, key)
      end
    end)
  end

  def fixture_credential, do: "local-fixture-only"
  def client, do: @client
  def tenant, do: @tenant
  def redirect_uri, do: @redirect

  def identity(subject),
    do: %{
      tenant_id: @tenant,
      client_id: @client,
      issuer: EntraConfig.issuer(@tenant),
      subject: subject
    }

  def bootstrap_admin(identity) do
    assert {:ok, admin} = Accounts.bootstrap(identity, [:admin])
    assert {:ok, session} = authenticate(admin.id)
    session
  end

  def authenticate(id) do
    # Lifecycle tests start after token verification. Router tests exercise
    # the verification step through the actual provider strategy.
    {:ok, registration} = EntraConfig.enabled()
    binding = StaffAccess.registration_binding(registration)
    StaffLifecycle.authenticate(resolve(id), %Scope{action: :sign_in_with_entra, target: binding})
  end

  def reject_audit(event, operation) do
    Process.put({VoelgoedAi.Accounts.StaffLifecycle, :reject_audit}, event)
    operation.()
  after
    Process.delete({VoelgoedAi.Accounts.StaffLifecycle, :reject_audit})
  end

  def resolve(id) do
    {:ok, row} =
      StaffUser
      |> Ash.Query.for_read(:resolve_staff, %{id: id},
        actor: %Scope{action: :resolve_staff, target: id}
      )
      |> Ash.read_one()

    row
  end

  defp clean(subjects) do
    Repo.transact(fn ->
      {:ok, _} =
        SQL.query(
          Repo,
          """
          DELETE FROM audit_events
          WHERE target_id IN (
            SELECT id FROM staff_users WHERE tenant_id = $1 AND identity_client_id = $2
            AND identity_subject = ANY($3)
          )
          """,
          [@tenant, @client, subjects]
        )

      SQL.query(
        Repo,
        """
        DELETE FROM staff_users WHERE tenant_id = $1 AND identity_client_id = $2
        AND identity_subject = ANY($3)
        """,
        [@tenant, @client, subjects]
      )
    end)
  end
end

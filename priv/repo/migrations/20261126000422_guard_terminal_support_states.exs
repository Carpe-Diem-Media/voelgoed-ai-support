defmodule VoelgoedAi.Repo.Migrations.GuardTerminalSupportStates do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION prevent_terminal_support_state_change() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'terminal support state cannot change'
        USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER outbound_deliveries_terminal_state
    BEFORE UPDATE OF state ON outbound_deliveries
    FOR EACH ROW WHEN (
      OLD.state IN ('sent', 'abandoned', 'cancelled', 'failed')
      AND OLD.state IS DISTINCT FROM NEW.state
    )
    EXECUTE FUNCTION prevent_terminal_support_state_change()
    """)

    execute("""
    CREATE TRIGGER support_runs_terminal_state
    BEFORE UPDATE OF state ON support_runs
    FOR EACH ROW WHEN (
      OLD.state IN ('completed', 'cancelled', 'superseded', 'failed')
      AND OLD.state IS DISTINCT FROM NEW.state
    )
    EXECUTE FUNCTION prevent_terminal_support_state_change()
    """)
  end

  def down do
    execute("DROP TRIGGER support_runs_terminal_state ON support_runs")
    execute("DROP TRIGGER outbound_deliveries_terminal_state ON outbound_deliveries")
    execute("DROP FUNCTION prevent_terminal_support_state_change()")
  end
end

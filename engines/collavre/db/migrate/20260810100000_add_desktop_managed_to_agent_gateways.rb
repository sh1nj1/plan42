# frozen_string_literal: true

class AddDesktopManagedToAgentGateways < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_gateways, :desktop_managed, :boolean, default: false, null: false unless column_exists?(:agent_gateways, :desktop_managed)
    backfill_legacy_desktop_gateway
    add_index :agent_gateways, :desktop_managed, unique: true, where: "desktop_managed", name: "index_agent_gateways_on_desktop_managed" unless index_exists?(:agent_gateways, name: "index_agent_gateways_on_desktop_managed")
  end

  def down
    remove_index :agent_gateways, name: "index_agent_gateways_on_desktop_managed" if index_exists?(:agent_gateways, name: "index_agent_gateways_on_desktop_managed")
    remove_column :agent_gateways, :desktop_managed if column_exists?(:agent_gateways, :desktop_managed)
  end

  private

  def backfill_legacy_desktop_gateway
    # Legacy records have no dedicated marker. A generated CLI preset linked
    # to the gateway is the durable signature; tenant ID and display fields
    # alone remain user-editable and must not cause a gateway to be adopted.
    legacy_gateway_ids = select_values(<<~SQL.squish)
      SELECT id FROM agent_gateways
      WHERE desktop_managed = FALSE
      AND tenant_id = 'collavre-desktop'
      AND base_url LIKE 'http://127.0.0.1:%'
      AND EXISTS (
        SELECT 1 FROM users
        WHERE users.agent_gateway_id = agent_gateways.id
        AND users.created_by_id = agent_gateways.owner_id
        AND users.email IN (
          'collavre-desktop-claude-code@ai.local',
          'collavre-desktop-codex@ai.local'
        )
        AND users.llm_vendor = 'cli_proxy'
      )
    SQL
    return unless legacy_gateway_ids.one?

    execute "UPDATE agent_gateways SET desktop_managed = TRUE WHERE id = #{connection.quote(legacy_gateway_ids.first)}"
  end
end

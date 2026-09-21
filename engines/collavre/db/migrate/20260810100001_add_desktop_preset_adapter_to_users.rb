# frozen_string_literal: true

class AddDesktopPresetAdapterToUsers < ActiveRecord::Migration[8.1]
  PRESET_EMAILS = {
    "claude" => "collavre-desktop-claude-code@ai.local",
    "codex" => "collavre-desktop-codex@ai.local"
  }.freeze

  def up
    add_column :users, :desktop_preset_adapter, :string unless column_exists?(:users, :desktop_preset_adapter)
    backfill_legacy_desktop_presets
    add_index :users, :desktop_preset_adapter, unique: true,
                                               where: "desktop_preset_adapter IS NOT NULL",
                                               name: "index_users_on_desktop_preset_adapter" unless index_exists?(:users, name: "index_users_on_desktop_preset_adapter")
  end

  def down
    remove_index :users, name: "index_users_on_desktop_preset_adapter" if index_exists?(:users, name: "index_users_on_desktop_preset_adapter")
    remove_column :users, :desktop_preset_adapter if column_exists?(:users, :desktop_preset_adapter)
  end

  private

  def backfill_legacy_desktop_presets
    PRESET_EMAILS.each do |adapter, email|
      execute <<~SQL.squish
        UPDATE users
        SET desktop_preset_adapter = #{connection.quote(adapter)}
        WHERE desktop_preset_adapter IS NULL
        AND email = #{connection.quote(email)}
        AND llm_vendor = 'cli_proxy'
        AND agent_gateway_id IN (
          SELECT id FROM agent_gateways WHERE desktop_managed = TRUE
        )
      SQL
    end
  end
end

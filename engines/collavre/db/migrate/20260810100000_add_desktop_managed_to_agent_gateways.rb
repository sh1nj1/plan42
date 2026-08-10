# frozen_string_literal: true

class AddDesktopManagedToAgentGateways < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_gateways, :desktop_managed, :boolean, default: false, null: false
    add_index :agent_gateways, :desktop_managed, unique: true, where: "desktop_managed", name: "index_agent_gateways_on_desktop_managed"
  end
end

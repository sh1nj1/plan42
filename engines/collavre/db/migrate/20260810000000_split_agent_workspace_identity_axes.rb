# frozen_string_literal: true

# The CLI proxy now carries two identity axes: X-CLI-Proxy-User-ID selects the
# OS worker holding the engine credentials, and X-CLI-Proxy-Workspace-ID selects
# a path workspace below that worker's HOME. Split the single proxy_user_id into
# those axes so engine login is per Collavre user while skills and workspace
# config stay per agent.
class SplitAgentWorkspaceIdentityAxes < ActiveRecord::Migration[8.0]
  class MigrationWorkspace < ActiveRecord::Base
    self.table_name = "agent_workspaces"
  end

  def up
    rename_column :agent_workspaces, :proxy_user_id, :proxy_credential_id
    add_column :agent_workspaces, :proxy_workspace_id, :string

    MigrationWorkspace.reset_column_information
    MigrationWorkspace.find_each do |workspace|
      workspace.update_columns(
        proxy_workspace_id: "agent-#{workspace.agent_id}",
        proxy_credential_id: credential_id_for(workspace)
      )
    end

    change_column_null :agent_workspaces, :proxy_workspace_id, false
  end

  def down
    MigrationWorkspace.reset_column_information
    MigrationWorkspace.find_each do |workspace|
      workspace.update_columns(proxy_credential_id: legacy_proxy_user_id_for(workspace))
    end

    remove_column :agent_workspaces, :proxy_workspace_id
    rename_column :agent_workspaces, :proxy_credential_id, :proxy_user_id
  end

  private

  def credential_id_for(workspace)
    workspace.user_id ? "user-#{workspace.user_id}" : "agent-#{workspace.agent_id}"
  end

  def legacy_proxy_user_id_for(workspace)
    return "agent-#{workspace.agent_id}" unless workspace.user_id

    "agent-#{workspace.agent_id}--user-#{workspace.user_id}"
  end
end

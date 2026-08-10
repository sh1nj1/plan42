# frozen_string_literal: true

# The CLI proxy now carries two identity axes: X-CLI-Proxy-User-ID selects the
# OS worker holding the engine credentials, and X-CLI-Proxy-Workspace-ID selects
# a path workspace below that worker's HOME. Split the single proxy_user_id into
# those axes so engine login is per Collavre user while skills and workspace
# config stay per agent.
#
# Expand only. bin/docker-entrypoint runs db:migrate while the previous release
# is still serving requests against the same database, so proxy_user_id has to
# stay readable and writable until every process runs the new code. The new
# columns are therefore nullable here and the old one merely loses its NOT NULL,
# which also keeps a Kamal rollback working. The contract half — dropping
# proxy_user_id and adding NOT NULL to the two new columns — belongs to a later
# release, once no process writes the legacy column anymore.
class SplitAgentWorkspaceIdentityAxes < ActiveRecord::Migration[8.0]
  class MigrationWorkspace < ActiveRecord::Base
    self.table_name = "agent_workspaces"
  end

  def up
    add_column :agent_workspaces, :proxy_credential_id, :string
    add_column :agent_workspaces, :proxy_workspace_id, :string

    MigrationWorkspace.reset_column_information
    MigrationWorkspace.find_each do |workspace|
      workspace.update_columns(
        proxy_workspace_id: "agent-#{workspace.agent_id}",
        proxy_credential_id: credential_id_for(workspace)
      )
    end

    change_column_null :agent_workspaces, :proxy_user_id, true
  end

  def down
    MigrationWorkspace.reset_column_information
    MigrationWorkspace.where(proxy_user_id: nil).find_each do |workspace|
      workspace.update_columns(proxy_user_id: legacy_proxy_user_id_for(workspace))
    end

    change_column_null :agent_workspaces, :proxy_user_id, false
    remove_column :agent_workspaces, :proxy_workspace_id
    remove_column :agent_workspaces, :proxy_credential_id
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

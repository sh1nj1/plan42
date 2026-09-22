# frozen_string_literal: true

require "digest"

# Identifies a workspace callback token by its Doorkeeper token id rather than
# its application's (mutable) name, and tags /mcp tool rows with the workspace
# whose callback token made the call and a digest of its arguments, so
# cli_proxy events can reconcile them call by call.
class LinkToolUsagesToAgentWorkspaces < ActiveRecord::Migration[8.0]
  class AgentWorkspaceRecord < ActiveRecord::Base
    self.table_name = "agent_workspaces"

    encrypts :callback_token, deterministic: false
  end

  class AccessTokenRecord < ActiveRecord::Base
    self.table_name = "oauth_access_tokens"
  end

  def up
    add_column :agent_workspaces, :callback_access_token_id, :bigint
    add_index :agent_workspaces, :callback_access_token_id, unique: true
    add_column :tool_usages, :agent_workspace_id, :bigint
    add_index :tool_usages, [ :agent_workspace_id, :tool_name, :occurred_at ], name: "index_tool_usages_on_workspace_tool_and_time"
    add_column :tool_usages, :arguments_digest, :string

    AgentWorkspaceRecord.reset_column_information
    AgentWorkspaceRecord.find_each do |workspace|
      plaintext = workspace.callback_token.to_s
      next if plaintext.empty?

      token_id = AccessTokenRecord.where(token: [ "sha256$#{Digest::SHA256.hexdigest(plaintext)}", plaintext ]).pick(:id)
      workspace.update_columns(callback_access_token_id: token_id) if token_id
    end
  end

  def down
    remove_column :tool_usages, :arguments_digest
    remove_index :tool_usages, name: "index_tool_usages_on_workspace_tool_and_time"
    remove_column :tool_usages, :agent_workspace_id
    remove_index :agent_workspaces, :callback_access_token_id
    remove_column :agent_workspaces, :callback_access_token_id
  end
end

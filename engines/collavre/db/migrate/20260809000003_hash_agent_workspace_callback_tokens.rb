# frozen_string_literal: true

require "digest"

class HashAgentWorkspaceCallbackTokens < ActiveRecord::Migration[8.0]
  PREFIX = "sha256$"

  class AgentWorkspaceRecord < ActiveRecord::Base
    self.table_name = "agent_workspaces"

    encrypts :callback_token, deterministic: false
  end

  class AccessTokenRecord < ActiveRecord::Base
    self.table_name = "oauth_access_tokens"
  end

  def up
    each_workspace_token do |plaintext|
      token = AccessTokenRecord.find_by(token: plaintext)
      token&.update_columns(token: encoded(plaintext))
    end
  end

  def down
    each_workspace_token do |plaintext|
      token = AccessTokenRecord.find_by(token: encoded(plaintext))
      token&.update_columns(token: plaintext)
    end
  end

  private

  def each_workspace_token
    AgentWorkspaceRecord.find_each do |workspace|
      plaintext = workspace.callback_token
      yield plaintext if plaintext.present?
    end
  end

  def encoded(plaintext)
    "#{PREFIX}#{Digest::SHA256.hexdigest(plaintext)}"
  end
end

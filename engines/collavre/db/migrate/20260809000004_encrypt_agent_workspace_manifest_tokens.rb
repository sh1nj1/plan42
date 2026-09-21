# frozen_string_literal: true

require "digest"

class EncryptAgentWorkspaceManifestTokens < ActiveRecord::Migration[8.0]
  class AgentWorkspaceRecord < ActiveRecord::Base
    self.table_name = "agent_workspaces"

    encrypts :manifest_token, deterministic: false
  end

  def up
    add_column :agent_workspaces, :manifest_token_digest, :string

    say_with_time "Encrypting agent workspace manifest capabilities" do
      transform_tokens(encrypt: true)
    end

    change_column_null :agent_workspaces, :manifest_token_digest, false
    remove_index :agent_workspaces, :manifest_token
    add_index :agent_workspaces, :manifest_token_digest, unique: true
  end

  def down
    remove_index :agent_workspaces, :manifest_token_digest

    say_with_time "Restoring plaintext agent workspace manifest capabilities" do
      transform_tokens(encrypt: false)
    end

    remove_column :agent_workspaces, :manifest_token_digest
    add_index :agent_workspaces, :manifest_token, unique: true
  end

  private

  def transform_tokens(encrypt:)
    connection = ActiveRecord::Base.connection
    encryptor = AgentWorkspaceRecord.type_for_attribute(:manifest_token)

    AgentWorkspaceRecord.reset_column_information
    rows = connection.select_all("SELECT id, manifest_token FROM agent_workspaces").to_a
    rows.each do |row|
      raw_token = row.fetch("manifest_token")
      plaintext = encrypted?(raw_token) ? encryptor.deserialize(raw_token) : raw_token
      stored = encrypt ? encryptor.serialize(plaintext) : plaintext
      assignments = [ "manifest_token = #{connection.quote(stored)}" ]
      assignments << "manifest_token_digest = #{connection.quote(Digest::SHA256.hexdigest(plaintext))}" if encrypt

      connection.execute(
        "UPDATE agent_workspaces SET #{assignments.join(', ')} WHERE id = #{connection.quote(row.fetch('id'))}"
      )
    end
  end

  def encrypted?(value)
    value.start_with?("{") && value.include?('"p":')
  end
end

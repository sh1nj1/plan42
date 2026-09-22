# frozen_string_literal: true

module Collavre
  class ToolUsage < ApplicationRecord
    self.table_name = "tool_usages"
    # internal: RubyLLM tool loop of an in-process agent
    # mcp: external client calling Collavre tools through /mcp
    # cli_proxy: tool events reported by cli-openai-proxy (x_cli_events)
    SOURCES = %w[internal mcp cli_proxy].freeze

    validates :event_key, :execution_id, :tool_name, :occurred_at, presence: true
    validates :source, inclusion: { in: SOURCES }
    validates :requester_kind, inclusion: { in: %w[human joint unknown] }
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

    after_create :index_requesters

    def self.requested_by(user_id)
      where(id: Requester.where(user_id: user_id).select(:tool_usage_id))
    end

    def self.visible_to(user)
      return none unless user
      return all if user.system_admin?

      where(owner_id: user.id).or(requested_by(user.id))
    end
    private

    def index_requesters
      return if requester_ids.empty?

      Requester.insert_all!(requester_ids.uniq.map { |user_id| { tool_usage_id: id, user_id: user_id } })
    end
  end
end

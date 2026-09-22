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

    # Collavre tools report expected failures as { error: "..." } instead of raising.
    # meta_tool's run action wraps the inner tool's result as { tool:, result: }.
    def self.failed_result?(result)
      return false unless result.is_a?(Hash)
      return true if result[:error].present? || result["error"].present?

      wrapped = result.key?(:tool) || result.key?("tool")
      wrapped && failed_result?(result[:result] || result["result"])
    end

    # Fingerprint of a call's arguments, so a cli_proxy result can find the /mcp
    # row of the same call. Key order and symbol vs string keys don't matter.
    def self.arguments_digest(arguments)
      return unless arguments.is_a?(Hash)

      Digest::SHA256.hexdigest(JSON.generate(canonical_arguments(arguments)))
    end

    def self.canonical_arguments(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, canonical_arguments(item) ] }.sort.to_h
      when Array then value.map { |item| canonical_arguments(item) }
      when Float then value.finite? && value == value.floor ? value.to_i : value
      else value
      end
    end
    private_class_method :canonical_arguments

    def self.elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end

    private

    def index_requesters
      return if requester_ids.empty?

      Requester.insert_all!(requester_ids.uniq.map { |user_id| { tool_usage_id: id, user_id: user_id } })
    end
  end
end

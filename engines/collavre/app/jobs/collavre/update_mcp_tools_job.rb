# frozen_string_literal: true

module Collavre
  # Re-derives a creative's MCP tool definitions from its description HTML.
  # Runs off the request/save path (enqueued from Creative after_commit) so the
  # Nokogiri parsing and tool upserts never block a synchronous save.
  class UpdateMcpToolsJob < ApplicationJob
    queue_as :default

    def perform(creative_id)
      creative = Creative.find_by(id: creative_id)
      return unless creative

      McpService.new.update_from_creative(creative)
    end
  end
end

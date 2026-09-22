# frozen_string_literal: true

module Collavre
  module CliProxy
    class EngineUnauthenticatedError < StandardError
      attr_reader :engine, :workspace

      def initialize(engine:, workspace:)
        @engine = engine
        @workspace = workspace
        super("Engine authentication required")
      end

      # RubyLLM preserves the structured SSE body, but maps its HTTP status to
      # 400. The proxy's machine code is authoritative for both transports.
      def self.from_response(error, workspace:)
        return unless error.respond_to?(:response)

        body = error.response&.body
        body = JSON.parse(body) if body.is_a?(String)
        detail = body.is_a?(Hash) && body["error"]
        return unless detail.is_a?(Hash) && detail["code"] == "engine_unauthenticated"
        return unless %w[claude codex].include?(detail["engine"])

        new(engine: detail["engine"], workspace: workspace)
      rescue JSON::ParserError
        nil
      end
    end
  end
end

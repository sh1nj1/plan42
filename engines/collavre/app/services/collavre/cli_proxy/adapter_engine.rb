# frozen_string_literal: true

module Collavre
  module CliProxy
    # Maps an agent's model id onto the proxy engine whose credential its runs
    # spend. `/health/ready` reports state per engine, so this is what turns
    # "the gateway is degraded" into "this particular agent can still run".
    module AdapterEngine
      MODEL_PREFIX = "paperclip/"

      BY_ADAPTER = {
        "claude_local" => "claude",
        "codex_local" => "codex",
        "codex_custom" => "codex_custom"
      }.freeze

      # nil for anything not recognized here. A proxy that ships a new adapter
      # must not have its agents reported offline by a Collavre that has never
      # heard of the engine behind it — nil falls back to the gateway rollup.
      def self.for_model(model)
        return nil unless model.to_s.start_with?(MODEL_PREFIX)

        BY_ADAPTER[model.to_s.delete_prefix(MODEL_PREFIX).split("/").first]
      end
    end
  end
end

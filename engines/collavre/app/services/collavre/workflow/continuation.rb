# frozen_string_literal: true

module Collavre
  module Workflow
    # Only a persisted child outbox can carry a chain across destination topics.
    module Continuation
      def self.chain_for(context)
        parent_id = context.dig("workflow", "execution_id")
        return unless parent_id
        row = Outbox.find_by(execution_id: parent_id, key: "child")
        return unless row && %w[event creative topic comment].all? { |key| row.context[key] == context[key] }
        row.execution.chain
      end
    end
  end
end

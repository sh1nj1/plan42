# frozen_string_literal: true

module Collavre
  module Workflow
    class DispatchOutcome < Data.define(:agents, :workflow_execution_id, :reason)
      def workflow_handled? = workflow_execution_id.present?
    end
  end
end

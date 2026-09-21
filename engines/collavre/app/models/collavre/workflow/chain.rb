# frozen_string_literal: true

module Collavre
  module Workflow
    class Chain < ApplicationRecord
      self.table_name = "workflow_chains"
      has_many :executions, class_name: "Collavre::Workflow::Execution", dependent: :restrict_with_exception

      MAX_DEPTH = 8
      MAX_ABSOLUTE_DEPTH = 64
      MAX_TASKS = 16
      MAX_STEPS = 16

      def depth_reason(depth)
        return "invalid_envelope" unless depth.is_a?(Integer) && depth >= root_depth && root_depth >= 0
        "depth_exceeded" if depth > MAX_ABSOLUTE_DEPTH || depth - root_depth > MAX_DEPTH
      end

      def reservation_reason(rule_id, depth, count)
        depth_reason(depth) ||
          ("cycle" if executions.where(rule_id: rule_id, reserved: true).exists?) ||
          ("step_budget_exhausted" if step_count >= MAX_STEPS) ||
          ("task_budget_exhausted" if task_count + count > MAX_TASKS)
      end
    end
  end
end

# frozen_string_literal: true

module Collavre
  # Permanent execution tombstones live with Task, not in the queue database.
  # Do not cascade these on task deletion: a stale serialized job can outlive it.
  class RetiredTaskExecution < ApplicationRecord
    self.table_name = "retired_task_executions"
  end
end

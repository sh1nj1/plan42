module Collavre
  class TaskMergedInstruction < ApplicationRecord
    self.table_name = "task_merged_instructions"
    belongs_to :task, class_name: "Collavre::Task"
  end
end

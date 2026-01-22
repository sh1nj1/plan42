module Collavre
  class TaskAction < ApplicationRecord
    self.table_name = "task_actions"

    belongs_to :task, class_name: "Collavre::Task"

    validates :action_type, presence: true
    validates :status, presence: true
  end
end

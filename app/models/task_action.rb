class TaskAction < ApplicationRecord
  belongs_to :task

  validates :action_type, presence: true
  validates :status, presence: true
end

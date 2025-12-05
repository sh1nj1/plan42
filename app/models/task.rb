class Task < ApplicationRecord
  belongs_to :agent, class_name: "User"
  has_many :task_actions, dependent: :destroy

  validates :name, presence: true
  validates :status, presence: true
end

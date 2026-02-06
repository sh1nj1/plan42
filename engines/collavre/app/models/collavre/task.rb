module Collavre
  class Task < ApplicationRecord
    self.table_name = "tasks"

    belongs_to :agent, class_name: "Collavre::User"
    has_many :task_actions, class_name: "Collavre::TaskAction", dependent: :destroy

    validates :name, presence: true

    scope :running_for_topic, ->(topic_id) { where(topic_id: topic_id, status: "running") }
    scope :queued_for_topic, ->(topic_id) { where(topic_id: topic_id, status: "queued").order(:created_at) }
  end
end

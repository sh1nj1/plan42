module Collavre
  class Task < ApplicationRecord
    self.table_name = "tasks"

    belongs_to :agent, class_name: "Collavre::User"
    has_many :task_actions, class_name: "Collavre::TaskAction", dependent: :destroy
    belongs_to :parent_task, class_name: "Collavre::Task", optional: true
    has_many :sub_tasks, class_name: "Collavre::Task", foreign_key: :parent_task_id, dependent: :destroy
    belongs_to :creative, class_name: "Collavre::Creative", optional: true

    validates :name, presence: true

    scope :running_for_topic, ->(topic_id) { where(topic_id: topic_id, status: "running") }
    scope :queued_for_topic, ->(topic_id) { where(topic_id: topic_id, status: "queued").order(:created_at) }

    def workflow_parent?
      workflow_state.present? && parent_task_id.nil?
    end

    def all_sub_tasks_done?
      sub_tasks.where.not(status: %w[done cancelled]).empty?
    end
  end
end

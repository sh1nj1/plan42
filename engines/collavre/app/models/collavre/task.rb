module Collavre
  class Task < ApplicationRecord
    self.table_name = "tasks"

    belongs_to :agent, class_name: "Collavre::User"
    has_many :task_actions, class_name: "Collavre::TaskAction", dependent: :destroy
    belongs_to :parent_task, class_name: "Collavre::Task", optional: true
    has_many :sub_tasks, class_name: "Collavre::Task", foreign_key: :parent_task_id, dependent: :destroy
    belongs_to :creative, class_name: "Collavre::Creative", optional: true

    validates :name, presence: true

    after_update_commit :check_trigger_loop_completion, if: :trigger_loop_candidate?

    scope :running_for_topic, ->(topic_id, creative_id = nil) {
      rel = where(topic_id: topic_id, status: "running")
      rel = rel.where(creative_id: creative_id) if creative_id
      rel
    }
    scope :queued_for_topic, ->(topic_id, creative_id = nil) {
      rel = where(topic_id: topic_id, status: "queued")
      rel = rel.where(creative_id: creative_id) if creative_id
      rel.order(:created_at)
    }

    # Check if agent already has a running task triggered by the same comment
    def self.duplicate_running_for_comment?(agent_id, comment_id)
      where(agent_id: agent_id, status: "running", trigger_event_name: "comment_created")
        .find_each do |task|
        return true if task.trigger_event_payload&.dig("comment", "id").to_s == comment_id.to_s
      end
      false
    end

    def workflow_parent?
      workflow_state.present? && parent_task_id.nil?
    end

    def all_sub_tasks_done?
      sub_tasks.where.not(status: %w[done cancelled]).empty?
    end

    private

    def trigger_loop_candidate?
      saved_change_to_attribute?("status") && status == "done" &&
        trigger_event_name == "comment_created" &&
        creative&.parent&.drop_trigger_enabled?
    end

    def check_trigger_loop_completion
      loop_config = creative.parent.data&.dig("trigger", "loop")
      return unless loop_config && loop_config["state"] == "running"

      cooldown = (loop_config["cooldown_seconds"] || 10).to_i
      if cooldown > 0
        TriggerLoopCheckJob.set(wait: cooldown.seconds).perform_later(id)
      else
        TriggerLoopCheckJob.perform_later(id)
      end
    end
  end
end

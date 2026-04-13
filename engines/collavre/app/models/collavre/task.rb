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

    private

    def trigger_loop_candidate?
      return false unless saved_change_to_attribute?("status") && status == "done"
      return false unless trigger_event_name == "comment_created"
      return false unless creative&.parent&.drop_trigger_enabled?

      # Only trigger loop check for tasks in the loop's trigger topic
      # to avoid cross-topic contamination from unrelated AI conversations
      loop_config = creative.data&.dig("trigger", "loop")
      return false unless loop_config && loop_config["state"] == "running"

      trigger_topic_id = loop_config["trigger_topic_id"]
      trigger_topic_id.nil? || trigger_topic_id == topic_id
    end

    def check_trigger_loop_completion
      loop_config = creative.data&.dig("trigger", "loop")
      cooldown = (loop_config&.dig("cooldown_seconds") || 10).to_i
      if cooldown > 0
        TriggerLoopCheckJob.set(wait: cooldown.seconds).perform_later(id)
      else
        TriggerLoopCheckJob.perform_later(id)
      end
    end
  end
end

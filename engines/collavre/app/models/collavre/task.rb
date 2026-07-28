module Collavre
  class Task < ApplicationRecord
    self.table_name = "tasks"

    belongs_to :agent, class_name: "Collavre::User"
    has_many :task_actions, class_name: "Collavre::TaskAction", dependent: :destroy
    belongs_to :parent_task, class_name: "Collavre::Task", optional: true
    has_many :sub_tasks, class_name: "Collavre::Task", foreign_key: :parent_task_id, dependent: :destroy
    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    has_one :reply_comment, class_name: "Collavre::Comment", foreign_key: :task_id, dependent: :nullify

    validates :name, presence: true

    enum :status, {
      pending: "pending",
      queued: "queued",
      running: "running",
      delegated: "delegated",
      pending_approval: "pending_approval",
      done: "done",
      failed: "failed",
      cancelled: "cancelled",
      escalated: "escalated"
    }, default: :pending

    after_update_commit :check_trigger_loop_completion, if: :trigger_loop_candidate?
    after_update_commit :broadcast_stop_button_removal, if: :became_terminal?
    after_update_commit :restore_undelivered_dispatches, if: :ended_without_delivering?

    scope :running_for_topic, ->(topic_id, creative_id = nil) {
      rel = where(topic_id: topic_id, status: %w[running delegated])
      rel = rel.where(creative_id: creative_id) if creative_id
      rel
    }
    scope :queued_for_topic, ->(topic_id, creative_id = nil) {
      rel = where(topic_id: topic_id, status: "queued")
      rel = rel.where(creative_id: creative_id) if creative_id
      rel.order(:created_at)
    }
    # Tasks that hold a topic concurrency slot: running/delegated (executing)
    # plus pending — a task that has been claimed (dequeue_next_for_topic moves a
    # waiter queued -> pending, a retry re-queues to pending, initial dispatch
    # creates pending) but whose AiAgentJob has not started yet — plus
    # pending_approval — a task paused awaiting tool approval that intentionally
    # keeps its resource (AiAgentJob sets should_release = false) and does NOT
    # drain the topic queue (dequeue_next_for_topic only fires on terminal
    # statuses done/failed/cancelled/escalated). Orphan detection must count all
    # of these, otherwise a claimed-but-not-started or approval-paused slot looks
    # free and a second waiter gets promoted into the same slot.
    scope :occupying_topic_slot, ->(topic_id, creative_id = nil) {
      rel = where(topic_id: topic_id, status: %w[running delegated pending pending_approval])
      rel = rel.where(creative_id: creative_id) if creative_id
      rel
    }

    # Check if agent already has an in-flight task triggered by the same comment.
    # Treats "delegated" as in-flight: a Claude Channel task that is waiting on
    # an external MCP reply is still active work — re-dispatching the same
    # comment would produce duplicate replies.
    def self.duplicate_running_for_comment?(agent_id, comment_id)
      where(agent_id: agent_id, status: %w[running delegated], trigger_event_name: "comment_created")
        .find_each do |task|
        return true if task.trigger_event_payload&.dig("comment", "id").to_s == comment_id.to_s
      end
      false
    end

    # Replay the after_update_commit callbacks when the status transition was
    # made via an UPDATE that bypassed callbacks (e.g. update_all in an atomic
    # claim flow). The private callback predicates rely on
    # saved_change_to_attribute? which is false outside a save lifecycle, so
    # the callbacks themselves would no-op when called directly. This method
    # is the supported escape hatch for AgentsController#finalize_claimed_task
    # to drive the same side effects (trigger-loop continuation + stop-button
    # broadcast) once the related reply_comment has been persisted.
    def fire_completion_callbacks_after_external_claim
      check_trigger_loop_completion if trigger_loop_completion_eligible?
      broadcast_stop_button_removal if terminal_status?
    end

    private

    def trigger_loop_candidate?
      return false unless saved_change_to_attribute?("status")

      trigger_loop_completion_eligible?
    end

    # State-only eligibility check (no save-lifecycle dependency).
    # Reused by trigger_loop_candidate? for the callback path and by
    # fire_completion_callbacks_after_external_claim for explicit replay.
    def trigger_loop_completion_eligible?
      return false unless status == "done"
      return false unless trigger_event_name == "comment_created"
      return false unless creative&.parent&.drop_trigger_enabled?

      # Only trigger loop check for tasks in the loop's trigger topic
      # to avoid cross-topic contamination from unrelated AI conversations
      loop_config = creative.data&.dig("trigger", "loop")
      return false unless loop_config && loop_config["state"] == "running"

      trigger_topic_id = loop_config["trigger_topic_id"]
      trigger_topic_id.nil? || trigger_topic_id == topic_id
    end

    def became_terminal?
      saved_change_to_attribute?("status") && terminal_status?
    end

    # This turn was dropping other agents' dispatches on the strength of having
    # read their comments, and then died without answering anything. Those
    # dispatches have to come back — see Orchestration::DeliveryRecord.restore!.
    #
    # A status callback rather than a call site: AiAgentJob's rescue and
    # StuckDetector both end a turn this way, and only one of them runs for a
    # process that was killed outright.
    def ended_without_delivering?
      return false unless saved_change_to_attribute?("status")
      return false unless status.in?(Orchestration::DeliveryRecord::UNDELIVERED_TERMINAL_STATUSES)

      Orchestration::DeliveryRecord.ids_in(trigger_event_payload).any?
    end

    def restore_undelivered_dispatches
      Orchestration::DeliveryRecord.restore!(self)
    end

    def terminal_status?
      status.in?(%w[done cancelled failed])
    end

    def broadcast_stop_button_removal
      comment = reply_comment
      return unless comment

      comment.broadcast_replace_to(
        [ comment.creative, :comments ],
        partial: "collavre/comments/comment",
        locals: { comment: comment, streaming: false }
      )
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

module Collavre
  class Task < ApplicationRecord
    self.table_name = "tasks"

    belongs_to :agent, class_name: "Collavre::User"
    has_many :task_actions, class_name: "Collavre::TaskAction", dependent: :destroy
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
    after_update_commit :schedule_onboarding_cleanup, if: :became_inactive?

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

    # Of the slot-occupying statuses, these have no live worker to run
    # AiAgentJob's ensure-block drain, so whoever cancels one must release the
    # slot itself.
    HELD_SLOT_WITHOUT_WORKER = %w[pending delegated pending_approval].freeze

    # Work still worth a typing indicator — and the Stop button that only exists
    # inside it: everything occupying_topic_slot counts, plus queued, a waiter
    # not yet promoted. delegated and pending_approval look idle but are not, the
    # job returned holding the slot while it awaits an MCP /reply or a tool
    # approval, and #cancel still accepts both. Kept here rather than in the
    # client so one list decides it.
    ACTIVE_STATUSES = %w[running delegated pending pending_approval queued].freeze

    def active?
      ACTIVE_STATUSES.include?(status)
    end

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

    # What a persisted row says about whether this turn ever handed anything
    # over — ended_without_delivering? without the transition.
    #
    # Asked twice: by the callback of a status change, and by
    # RestoreDroppedDispatchesJob of a row it finds afterwards. Written once,
    # because a sweep deciding "terminal" where the callback decides this is how
    # a backstop comes to re-answer comments the turn had already answered.
    def ended_undelivered?
      payload = trigger_event_payload
      # Asked first, so that a row carrying both records is read as undelivered.
      # A resumed turn can legitimately carry both: an earlier attempt handed
      # off, while a later one failed before doing so. DeliveryRecord restores
      # that row but subtracts the comment ids the successful attempts carried,
      # leaving only the later attempt's undelivered comments.
      return true if status == "done" && Orchestration::DeliveryRecord.handoff_failed?(payload)

      # An ending is undelivered because the payload never reached the provider,
      # not because of the name of the ending. A turn stopped — or broken — after
      # the handoff has been read by the agent along with everything it
      # swallowed, and the product already shows that turn with its partial
      # reply. Only a turn that got far enough to record the handoff is exempt;
      # everything quieter than that still owes its dispatches back.
      return false if Orchestration::DeliveryRecord.handed_off?(payload)

      status.in?(Orchestration::DeliveryRecord::UNDELIVERED_TERMINAL_STATUSES)
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

    # A completed onboarding session may have stopped retrying its cleanup
    # while a tool approval waited indefinitely. Once that turn transitions out
    # of an active state, enqueue one final cleanup instead of polling forever.
    def became_inactive?
      saved_change_to_attribute?("status") &&
        status_before_last_save.in?(ACTIVE_STATUSES) &&
        !active?
    end

    def schedule_onboarding_cleanup
      # The deferred-cleanup marker may have been added after this task loaded
      # (for example, by onboarding reset), so do not inspect a stale belongs_to
      # association from the running task instance.
      creative = Creative.find_by(id: creative_id)
      onboarding = creative&.data&.fetch("onboarding", {})
      session_id = onboarding&.fetch("session_id", nil)
      return if session_id.blank?

      user = creative.user
      # A reset clears onboarding_completed_at for its replacement session.
      # The retiring session records its own deferred cleanup eligibility on
      # its tagged creatives, so its terminal turn remains able to finish
      # cleanup after the bounded retry window.
      return unless onboarding["cleanup_pending"] || user&.onboarding_completed_at?

      OnboardingCleanupJob.perform_later(user.id, session_id)
    end

    # This turn refused other dispatches on the strength of having read their
    # comments, and then died without answering anything. Those dispatches have
    # to come back — see Orchestration::DeliveryRecord.restore!.
    #
    # Only the status transition is decided here. Whether anything was actually
    # refused is asked inside restore!, off the persisted row: the drop record
    # is written by the refused dispatch in another process, so this object's
    # payload predates it and a check here would read `none` on every turn that
    # dropped something.
    #
    # A status callback rather than a call site: AiAgentJob's rescue and
    # StuckDetector both end a turn this way, and only one of them runs for a
    # process that was killed outright.
    #
    # `done` is an undelivered ending too when the turn recorded that its
    # request never reached the provider: AiClient#chat catches the error and
    # AiAgentJob finishes the task normally, so the status alone cannot say it.
    # Read off this object rather than the row because the flag is written by
    # this turn's own service, in this process, immediately before the status
    # update that fires this callback — unlike DROPPED_KEY, which the refused
    # dispatch writes from another process and restore! therefore re-reads.
    def ended_without_delivering?
      return false unless saved_change_to_attribute?("status")
      return false if ended_while_worker_settles?

      ended_undelivered?
    end

    # A turn ended from another process while its worker is still inside the
    # provider call, whose own account of the handoff does not exist yet.
    #
    # Stop is committed from a web request, and StuckDetector can fail a running
    # row from its recurring job. Both can beat AiAgentService's ensure, which
    # writes whether the payload reached the provider only after the call exits.
    # This callback fires before that evidence exists.
    #
    # So it declines, and the question is asked where the turn settles —
    # AiAgentJob's teardown, once the record is written. Behind that,
    # DeliveryRecord.restore_missed! covers an ending with no live worker to
    # settle anything.
    def ended_while_worker_settles?
      return false unless status_before_last_save == "running"
      return true if status == "cancelled"

      status == "failed" &&
        Orchestration::DeliveryRecord.worker_settling?(trigger_event_payload)
    end

    # Best effort, deliberately: this runs after the turn's own status is
    # committed, so an exception here propagates back into the update! that
    # ended the turn — and AiAgentJob's rescue answers that by writing `failed`
    # over a turn that had in fact finished and answered. The restore is
    # reconstructible from the row it was given, and
    # DeliveryRecord.restore_missed! is what asks again.
    def restore_undelivered_dispatches
      Orchestration::DeliveryRecord.restore!(self)
    rescue StandardError => e
      Rails.logger.error(
        "[Task] Restore failed for task #{id}: #{e.class}: #{e.message} — " \
        "leaving it to the restore sweep"
      )
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

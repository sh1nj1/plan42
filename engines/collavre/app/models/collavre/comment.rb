module Collavre
  class Comment < ApplicationRecord
    self.table_name = "comments"

    STREAMING_PLACEHOLDER_CONTENT = "..."
    # Authorless "⏳" waiting-notice system messages posted when an agent is
    # deferred for topic concurrency. AgentOrchestrator.cleanup_waiting_notices!
    # matches the same prefix to remove them once the waiter is dequeued.
    WAITING_NOTICE_PREFIX = "⏳"

    # Use non-namespaced partial path for backward compatibility
    def to_partial_path
      "comments/comment"
    end

    # A system "⏳" waiting notice (no author) telling a user their agent is
    # deferred because another task holds the topic's running slot.
    def waiting_notice?
      user_id.nil? && content.to_s.start_with?(WAITING_NOTICE_PREFIX)
    end

    # The task holding this topic's concurrency slot — the blocker this waiting
    # notice is about. Lets the notice render a stop button that cancels the
    # blocker (freeing the topic so the deferred waiter proceeds) instead of
    # being an anonymous dead end. Resolved at render time rather than stored on
    # task_id, which Task#reply_comment keys on (a shared task_id would make the
    # blocker's reply_comment ambiguous).
    #
    # Two gates keep the button honest:
    #   1. Only THIS notice's own topic-concurrency defer qualifies. The same "⏳"
    #      notice is also posted for :delayed decisions (busy / rate_limited),
    #      which schedule a delayed job WITHOUT queuing a topic waiter —
    #      cancelling some unrelated running task would not unblock them.
    #      topic_concurrency_defer is set only on the :deferred path, so a
    #      :delayed notice never shows the button even when an unrelated queued
    #      waiter happens to share the topic. The queued_for_topic check then
    #      confirms a waiter is still actually pending on the slot.
    #   2. Resolve the blocker over occupying_topic_slot, not just running/
    #      delegated: a holder paused on pending_approval still occupies the slot
    #      and is cancellable, so the button must stay visible for it.
    # Returns nil once no slot holder remains — at which point the notice itself
    # is cleaned up.
    def topic_blocking_task
      return @topic_blocking_task if defined?(@topic_blocking_task)

      @topic_blocking_task =
        if topic_concurrency_defer? && topic_id &&
           Collavre::Task.queued_for_topic(topic_id, creative_id).exists?
          Collavre::Task.occupying_topic_slot(topic_id, creative_id)
                        .includes(:agent).order(:created_at).first
        end
    end

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :approver, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :action_executed_by, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :task, class_name: "Collavre::Task", optional: true
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :quoted_comment, class_name: "Collavre::Comment", optional: true

    scope :public_only, -> { where(private: false) }

    scope :visible_to, ->(user) {
      where(
        "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
        false, user.id, user.id
      )
    }

    # review_type: nil = normal chat, 0 = review, 1 = question
    enum :review_type, { review: 0, question: 1 }, prefix: true

    # Must run before dependent: :destroy on comment_versions to clear FK
    before_destroy :nullify_selected_version

    has_many :activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
    has_many :comment_reactions, class_name: "Collavre::CommentReaction", dependent: :destroy
    has_many :comment_versions, class_name: "Collavre::CommentVersion", dependent: :destroy
    has_many :review_versions, class_name: "Collavre::CommentVersion", foreign_key: :review_comment_id, dependent: :nullify
    has_many :inbox_items, class_name: "Collavre::InboxItem", dependent: :nullify
    has_many :quoting_comments, class_name: "Collavre::Comment", foreign_key: :quoted_comment_id, dependent: :destroy
    has_one :snapshot_as_result, class_name: "Collavre::CommentSnapshot", foreign_key: :result_comment_id, dependent: :nullify
    belongs_to :selected_version, class_name: "Collavre::CommentVersion", optional: true

    has_many_attached :images, dependent: :purge_later

    include Broadcastable
    include Notifiable
    include Approvable
    include ClaudeChannelPermission

    attribute :skip_default_user, :boolean, default: false
    attribute :skip_dispatch, :boolean, default: false
    # Set by AgentOrchestrator.cleanup_waiting_notices! so destroying a notice as
    # part of *promoting* a waiter does not run the user-delete cancel cascade
    # (which would cancel other still-queued waiters in the same topic).
    attribute :suppress_waiter_cancellation, :boolean, default: false

    before_validation :use_origin_creative
    before_validation :assign_default_user, on: :create
    before_validation :assign_main_topic, on: :create
    before_save :apply_link_previews, if: :should_apply_link_previews?
    after_create_commit :dispatch_to_orchestration
    after_create_commit :resume_trigger_loop_if_awaiting

    validates :content, presence: true, unless: -> { images.attached? }
    validate :creative_must_be_origin_creative
    validate :images_must_be_images

    after_destroy_commit :cancel_pending_tasks

    def next_version_number
      (comment_versions.maximum(:version_number) || 0) + 1
    end

    def review_message?
      quoted_comment_id.present? && !review_type_question?
    end

    # public for db migration
    def creative_snippet
      creative.creative_snippet
    end

    # Build the dispatch payload for comment_created events.
    # Used by both after_create_commit callback and DropTriggerJob
    # to ensure a single source of truth (no payload drift).
    def dispatch_payload
      {
        comment: {
          id: id,
          content: content,
          user_id: user_id,
          from_ai: user&.searchable? || false,
          quoted_comment_id: quoted_comment_id
        }.compact,
        creative: {
          id: creative_id,
          description: creative&.description
        },
        topic: {
          id: topic_id
        },
        chat: {
          content: content
        }
      }
    end

    private

    def nullify_selected_version
      update_column(:selected_version_id, nil) if selected_version_id.present?
    end

    def cancel_pending_tasks
      # Cancel tasks triggered by this comment (no creative_id scoping —
      # CommentMoveService can change comment.creative_id without updating
      # existing tasks, so scoping would miss moved-comment tasks).
      # Include "delegated" so a deleted prompt also cancels Claude Channel
      # work that's still waiting on an external MCP reply — otherwise the
      # delegated task keeps holding the topic/agent slot until stuck recovery.
      Task.where(status: %w[pending running queued delegated]).find_each do |task|
        next unless task.trigger_event_payload&.dig("comment", "id") == id

        was_delegated = task.status == "delegated"
        task.update!(status: "cancelled")

        # Delegated tasks live past their job: the AiAgentJob already returned,
        # holding the agent slot under task.id and counting against the per-topic
        # serializer. Mirror the cancel path used elsewhere to free both.
        next unless was_delegated
        if task.agent
          Collavre::Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        end
        if task.parent_task_id.present?
          begin
            Collavre::Comments::WorkflowExecutor.new(task.parent_task).fail_subtask!(
              task, error_message: "Triggering comment was deleted"
            )
          rescue StandardError => e
            Rails.logger.error(
              "[Comment#cancel_pending_tasks] fail_subtask! failed for task #{task.id}: #{e.message}"
            )
          end
        end
        Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end

      # Cancel queued tasks when a user DELETES their waiting notice. Gated to
      # topic_concurrency_defer notices: only the :deferred path queues a topic
      # waiter, so a :delayed (busy / rate_limited) "⏳" notice — which shares the
      # prefix but has no waiter of its own — must not cancel an unrelated queued
      # waiter that happens to share the topic. Also skipped when the notice is
      # removed by promotion cleanup (suppress_waiter_cancellation): there the
      # waiter is being advanced, not abandoned, and cancelling other still-queued
      # waiters would drop their work (multi-slot orphan recovery must not cancel
      # the rest).
      if waiting_notice? && topic_concurrency_defer? && !suppress_waiter_cancellation
        cancel_queued_tasks_for_waiting_notice
      end
    end

    def cancel_queued_tasks_for_waiting_notice
      scope = Task.where(status: "queued", creative_id: creative_id)
      scope = topic_id ? scope.where(topic_id: topic_id) : scope.where(topic_id: nil)
      task = scope.order(created_at: :desc).first
      task&.update!(status: "cancelled")
    end

    def dispatch_to_orchestration
      return if private?
      return if skip_default_user  # system notices should not trigger AI
      return if skip_dispatch      # explicit opt-out (e.g., command processor responses)
      return if approval_action?   # approval button / 승인됨 message: human decision surface, never dispatch to an agent
      return unless user_id        # nil user = system message
      return if user&.ai_user?     # AI replies use A2aDispatcher, not this callback
      return unless creative
      # Inbox creatives hold the user's notifications AND ordinary conversations.
      # Only the System topic is special: it carries alarms/notifications (stuck
      # recovery, share notices, …) and must never trigger AI. Every OTHER inbox
      # topic — Main, Content, user threads, Claude Channel session topics — is an
      # ordinary conversation surface and dispatches exactly like a normal
      # (non-inbox) topic.
      #
      # A live Claude Channel session holds inbox-wide :feedback +
      # routing_expression="true", so it would otherwise be selected by the
      # Matcher for *every* dispatched inbox comment (leaking ordinary inbox
      # threads into the live session). That confinement now lives in
      # Orchestration::Matcher, which scopes a Claude session agent to its own
      # registered session topic — keeping non-System topics truly identical to a
      # normal topic whether or not a session is live.
      return if creative.inbox? && inbox_system_topic?

      # A Claude Channel session suspended on a native tool-permission prompt
      # parks its in-flight dispatch as a `delegated` task carrying a
      # pending_tool_call (stamped by /agent/notify when the prompt is relayed).
      # An intervening human comment posted while the task is parked is dispatched
      # normally — not suppressed. The delegated task holds the topic's only
      # concurrency slot (running_for_topic counts `delegated`,
      # topic_max_concurrent_jobs=1), so the scheduler defers the comment into a
      # `queued` task rather than a competing turn, and
      # AgentOrchestrator.dequeue_next_for_topic promotes it (refreshed to the
      # latest comment) when the parked task is finalized on /reply. Suppressing
      # it here would silently drop the follow-up instead of deferring it — worst
      # when the local Claude TUI answered the prompt, leaving pending_tool_call
      # set on the server for the rest of a locally-approved tool run.

      SystemEvents::Dispatcher.dispatch("comment_created", dispatch_payload)
    rescue StandardError => e
      Rails.logger.error(
        "[Comment#dispatch_to_orchestration] Failed for comment #{id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      )
      raise  # re-raise so calling jobs (e.g. DropTriggerJob) can retry
    end

    # The inbox System topic is the alarm/notification stream and must never
    # trigger AI orchestration. Matched by name (Creative::SYSTEM_TOPIC_NAME),
    # the same topic Creative#system_topic finds/creates and that stuck-recovery
    # and share notices post into.
    def inbox_system_topic?
      topic&.name == Creative::SYSTEM_TOPIC_NAME
    end

    def assign_default_user
      return if skip_default_user
      self.user ||= Collavre.current_user
    end

    # When a human user comments in a trigger topic that is awaiting user input,
    # auto-resume the trigger loop so the agent can continue working.
    def resume_trigger_loop_if_awaiting
      return unless user_id                # must have a user (not system)
      return if user&.ai_user?             # must be a human, not an AI agent
      return unless creative

      # Use pessimistic lock to prevent duplicate resume from concurrent comments
      iteration = nil
      max = nil
      creative.with_lock do
        loop_data = creative.data&.dig("trigger", "loop")
        return unless loop_data && loop_data["state"] == "awaiting_user"

        # Only resume if this comment is in the trigger topic
        trigger_topic_id = loop_data["trigger_topic_id"]
        return if trigger_topic_id.present? && trigger_topic_id != topic_id

        # Transition to running and post continue instruction atomically
        data = creative.data || {}
        trigger = data["trigger"] || {}
        loop_cfg = trigger["loop"] || {}
        iteration = loop_cfg["current_iteration"] || 0
        max = loop_cfg["max_iterations"] || 10
        loop_cfg["state"] = "running"
        trigger["loop"] = loop_cfg
        data["trigger"] = trigger
        creative.update!(data: data)
      end

      # Post continue instruction outside lock (state already committed)
      return unless iteration # guard: lock block returned early

      parent = creative.parent
      return unless parent&.drop_trigger_enabled?

      agent = parent.find_ai_agent(:write)
      return unless agent

      creative.comments.create!(
        content: "@#{agent.name}: #{I18n.t(
          'collavre.trigger_loop.user_resumed',
          iteration: iteration,
          max: max
        )}",
        topic_id: topic_id,
        private: false,
        user: creative.user,
        skip_dispatch: false
      )
    rescue StandardError => e
      Rails.logger.error(
        "[Comment#resume_trigger_loop_if_awaiting] Failed for comment #{id}: " \
        "#{e.class} #{e.message}"
      )
    end

    def assign_main_topic
      return if topic_id.present?
      return unless creative

      fallback = user || Collavre.current_user || creative.user
      self.topic = creative.main_topic(fallback_user: fallback)
    end

    def use_origin_creative
      return unless creative
      self.creative = creative.effective_origin
    end

    def creative_must_be_origin_creative
      return unless creative
      return unless creative.origin_id.present?

      errors.add(:creative, "must be an origin creative")
    end

    def should_apply_link_previews?
      will_save_change_to_content? && content.present?
    end

    def apply_link_previews
      self.content = CommentLinkFormatter.new(content).format
    rescue StandardError => e
      Rails.logger.warn("Comment link preview formatting failed: #{e.class} #{e.message}")
    end

    def images_must_be_images
      return unless images.attached?

      invalid_images = images.reject { |image| image.blob&.content_type&.start_with?("image/") }
      return if invalid_images.empty?

      errors.add(:images, "must be an image")
      invalid_images.each(&:purge)
    end
  end
end

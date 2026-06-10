module Collavre
  class Comment < ApplicationRecord
    self.table_name = "comments"

    STREAMING_PLACEHOLDER_CONTENT = "..."

    # Use non-namespaced partial path for backward compatibility
    def to_partial_path
      "comments/comment"
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

      # Cancel queued tasks when their waiting notice (system comment) is deleted
      cancel_queued_tasks_for_waiting_notice if waiting_notice?
    end

    def waiting_notice?
      user_id.nil? && content&.start_with?("⏳")
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
      return unless user_id        # nil user = system message
      return if user&.ai_user?     # AI replies use A2aDispatcher, not this callback
      return unless creative
      # Inbox creatives hold the user's notifications/DMs and normally must not
      # trigger AI orchestration. Exception: a Claude Channel agent session
      # registers its topic *inside* the inbox (Creative.inbox_for) and depends
      # on the orchestration pipeline (Matcher → Arbiter → AiAgentService) to
      # deliver comments to the running session. Scope the exception to actual
      # Claude Channel session topics (primary_agent is a claude_channel_agent?).
      # An inbox topic can be given any ai_user as primary_agent via
      # TopicsController#set_primary_agent; gating on mere primary_agent presence
      # would leak ordinary inbox DMs to the live Claude session, which holds
      # inbox-wide :feedback + routing_expression="true" and would be selected by
      # the Matcher for any dispatched inbox comment.
      return if creative.inbox? && !claude_channel_session_topic?

      # A Claude Channel session suspended on a native tool-permission prompt
      # parks its in-flight dispatch as a `delegated` task carrying a
      # pending_tool_call (stamped by /agent/notify when the prompt is relayed).
      # The allow/deny decision is made by clicking the approve/deny buttons on
      # the structured permission comment (see ClaudeChannelPermission below),
      # which relays the decision out-of-band over the agent stream. While the
      # task stays parked, an intervening human *text* comment is suppressed
      # rather than dispatched as a competing turn: the delegated task holds the
      # topic's only concurrency slot (running_for_topic counts `delegated`), so
      # a competing turn would defer behind the very task awaiting the decision.
      return if claude_channel_permission_pending?

      SystemEvents::Dispatcher.dispatch("comment_created", dispatch_payload)
    rescue StandardError => e
      Rails.logger.error(
        "[Comment#dispatch_to_orchestration] Failed for comment #{id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      )
      raise  # re-raise so calling jobs (e.g. DropTriggerJob) can retry
    end

    # True only when this comment's topic is an actual Claude Channel session
    # topic — it carries the registration marker (session_id) AND its
    # primary_agent is a claude_channel_agent? (llm_model "claude-code"). Used to
    # scope the inbox dispatch exception so ordinary inbox threads stay local.
    #
    # session_id is required, not just the Claude primary_agent: a Claude
    # channel ai_user can be assigned as primary_agent on an ordinary inbox
    # topic via TopicsController#set_primary_agent without ever registering a
    # session. Gating on the agent alone would dispatch that ordinary thread and
    # leak it to the live Claude session. session_id is exactly what
    # ClaudeChannelAdapter#session_topic? keys on, so the two stay consistent.
    def claude_channel_session_topic?
      topic&.session_id.present? && topic&.primary_agent&.claude_channel_agent?
    end

    # True when this topic has a Claude Channel session suspended on a native
    # tool-permission prompt — a `delegated` task carrying pending_tool_call
    # whose agent is a claude_channel_agent?. Used by dispatch_to_orchestration
    # to suppress an intervening human text comment instead of dispatching it as
    # a competing turn while the session awaits the button decision.
    def claude_channel_permission_pending?
      return false unless topic_id

      Task
        .where(topic_id: topic_id, status: "delegated")
        .where.not(pending_tool_call: nil)
        .includes(:agent)
        .any? { |task| task.agent&.claude_channel_agent? }
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

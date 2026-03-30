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
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :quoted_comment, class_name: "Collavre::Comment", optional: true

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

    attribute :skip_default_user, :boolean, default: false
    attribute :skip_dispatch, :boolean, default: false

    before_validation :use_origin_creative
    before_validation :assign_default_user, on: :create
    before_save :apply_link_previews, if: :should_apply_link_previews?
    after_create_commit :dispatch_to_orchestration

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
      # Cancel tasks triggered by this comment
      Task.where(status: %w[pending running queued]).each do |task|
        if task.trigger_event_payload&.dig("comment", "id") == id
          task.update!(status: "cancelled")
        end
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

      SystemEvents::Dispatcher.dispatch("comment_created", dispatch_payload)
    rescue StandardError => e
      Rails.logger.error(
        "[Comment#dispatch_to_orchestration] Failed for comment #{id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      )
      raise  # re-raise so calling jobs (e.g. DropTriggerJob) can retry
    end

    def assign_default_user
      return if skip_default_user
      self.user ||= Collavre.current_user
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

module Collavre
  class Comment < ApplicationRecord
    self.table_name = "comments"

    # Use non-namespaced partial path for backward compatibility
    def to_partial_path
      "comments/comment"
    end

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :approver, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :action_executed_by, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    has_many :activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
    has_many :comment_reactions, class_name: "Collavre::CommentReaction", dependent: :destroy


    has_many_attached :images, dependent: :purge_later

    before_validation :use_origin_creative
    before_validation :assign_default_user, on: :create
    before_save :apply_link_previews, if: :should_apply_link_previews?

    validates :content, presence: true, unless: -> { images.attached? }
    validate :creative_must_be_origin_creative
    validate :images_must_be_images

    after_create_commit :broadcast_create, :notify_write_users, :notify_mentions, :broadcast_badges
    after_update_commit :broadcast_update
    after_destroy_commit :broadcast_destroy, :broadcast_badges

    # public for db migration
    def creative_snippet
      creative.creative_snippet
    end

    def can_be_approved_by?(user)
      approval_status(user) == :ok
    end

    def approval_status(user)
      return :not_allowed unless user

      if action.blank?
        return :not_allowed unless approver == user
        return :missing_action
      end

      begin
        payload = JSON.parse(action)
      rescue JSON::ParserError
        return :invalid_action_format
      end
      return :invalid_action_format unless payload.is_a?(Hash)

      actions = Array(payload["actions"])
      actions = [ payload ] if actions.empty?

      requires_admin = actions.any? do |item|
        next false unless item.is_a?(Hash)
        action_type = item["action"] || item["type"]
        action_type == "approve_tool"
      end

      if requires_admin && SystemSetting.mcp_tool_approval_required?
        return user.system_admin? ? :ok : :admin_required
      end

      return :missing_approver if approver_id.blank?
      return :not_allowed unless approver == user

      :ok
    end

    private

    def create_inbox_item(owner, key, params = {})
      origin = creative&.effective_origin
      metadata = params.to_h.stringify_keys
      metadata["comment_id"] = id
      metadata["creative_id"] = origin&.id

      InboxItem.create!(
        owner: owner,
        message_key: key,
        message_params: metadata,
        comment: self,
        creative: origin,
        link: Collavre::Engine.routes.url_helpers.creative_comment_url(
          creative,
          self,
          Rails.application.config.action_mailer.default_url_options
        )
      )
    end

    def mentioned_emails
      return [] unless content
      content.scan(/@([\w.\-+]+@[a-zA-Z0-9\-.]+\.[a-zA-Z]{2,})/)
             .flatten
             .map(&:downcase)
             .uniq
    end

    def mentioned_names
      return [] unless content
      content.scan(/@([^:]+):/)
             .flatten
             .map(&:downcase)
             .uniq
    end

    def mentioned_users
      return Collavre.user_class.none unless user
      emails = mentioned_emails - [ user.email.downcase ]
      names = mentioned_names - [ user.name.downcase ]

      origin = creative.effective_origin
      mentionable_users = Collavre.user_class.mentionable_for(origin)

      scope = Collavre.user_class.none
      scope = scope.or(mentionable_users.where(email: emails)) if emails.any?
      scope = scope.or(mentionable_users.where("LOWER(name) IN (?)", names)) if names.any?
      scope
    end

    def broadcast_create
      return if private?
      broadcast_append_later_to([ creative, :comments ], target: "comments-list", partial: "collavre/comments/comment")
    end

    def broadcast_update
      return if private?
      broadcast_replace_later_to([ creative, :comments ], partial: "collavre/comments/comment")
    end

    def broadcast_destroy
      return if private? || !creative
      broadcast_remove_to([ creative, :comments ])
    end

    def broadcast_badges
      return unless creative
      Comment.broadcast_badges(creative)
    end

    def notify_write_users
      return if private? || !user
      base_creative = creative.effective_origin
      present_ids = CommentPresenceStore.list(base_creative.id)
      recipients = base_creative.all_shared_users(:write).map(&:user)
      recipients << base_creative.user
      recipients.compact!
      recipients.uniq!
      recipients.delete(user)
      recipients -= mentioned_users.to_a
      recipients.reject! { |u| present_ids.include?(u.id) }
      recipients.each do |recipient|
        create_inbox_item(
          recipient,
          "inbox.comment_added",
          { user: user.display_name, comment: content, creative: creative_snippet }
        )
      end
    end

    def notify_mentions
      return if private?
      mentioned_users.each do |mentioned|
        create_inbox_item(
          mentioned,
          "inbox.user_mentioned",
          { user: user.display_name, comment: content, creative: creative_snippet }
        )
      end
    end

    def assign_default_user
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

    def self.broadcast_badges(creative)
      origin = creative.effective_origin
      users = [ origin.user ].compact + origin.all_shared_users(:feedback).map(&:user)
      users.compact!
      users.uniq!
      return if users.empty?

      user_ids = users.map(&:id)

      # Batch load all comment read pointers for these users
      pointers = CommentReadPointer.where(user_id: user_ids, creative: origin).index_by(&:user_id)

      # Get present users once
      present_user_ids = CommentPresenceStore.list(origin.id)

      # Batch count queries - get counts grouped by user visibility
      # For public comments (visible to all)
      public_count = origin.comments.where(private: false).count

      # For private comments, get counts per user
      private_counts = origin.comments
        .where(private: true, user_id: user_ids)
        .group(:user_id)
        .count

      # Batch unread counts - first get the min last_read_id per user
      last_read_ids = pointers.transform_values { |p| p.last_read_comment_id || 0 }

      # Get unread public comments for each threshold
      unread_public_by_threshold = {}
      last_read_ids.values.uniq.each do |threshold|
        unread_public_by_threshold[threshold] = origin.comments
          .where(private: false)
          .where("comments.id > ?", threshold)
          .count
      end

      # Get unread private comments per user
      unread_private_counts = {}
      user_ids.each do |uid|
        threshold = last_read_ids[uid] || 0
        unread_private_counts[uid] = origin.comments
          .where(private: true, user_id: uid)
          .where("comments.id > ?", threshold)
          .count
      end

      users.each do |u|
        user_private_count = private_counts[u.id] || 0
        total_count = public_count + user_private_count

        threshold = last_read_ids[u.id] || 0
        unread_public = unread_public_by_threshold[threshold] || 0
        unread_private = unread_private_counts[u.id] || 0
        unread_count = unread_public + unread_private

        unread_count = 0 if present_user_ids.include?(u.id)

        Turbo::StreamsChannel.broadcast_replace_to(
          [ u, origin, :comment_badge ],
          target: "comment-badge-#{origin.id}",
          partial: "inbox/badge_component/count",
          locals: {
            count: unread_count,
            badge_id: "comment-badge-#{origin.id}",
            show_zero: total_count.positive?
          }
        )
      end
    end

    def self.broadcast_badge(creative, user)
      origin = creative.effective_origin
      visible_comments = origin.comments.where("comments.private = ? OR comments.user_id = ?", false, user.id)
      comments_count = visible_comments.count
      pointer = CommentReadPointer.find_by(user: user, creative: origin)
      last_read_id = pointer&.last_read_comment_id
      unread_scope = last_read_id ? visible_comments.where("comments.id > ?", last_read_id) : visible_comments
      unread_count = unread_scope.count
      unread_count = 0 if CommentPresenceStore.list(origin.id).include?(user.id)
      Turbo::StreamsChannel.broadcast_replace_to(
        [ user, origin, :comment_badge ],
        target: "comment-badge-#{origin.id}",
        partial: "inbox/badge_component/count",
        locals: {
          count: unread_count,
          badge_id: "comment-badge-#{origin.id}",
          show_zero: comments_count.positive?
        }
      )
    end
  end
end

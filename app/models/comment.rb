class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true

  before_validation :assign_default_user, on: :create
  before_save :apply_link_previews, if: :should_apply_link_previews?

  validates :content, presence: true

  after_create_commit :broadcast_create, :notify_write_users, :notify_mentions, :broadcast_badges
  after_update_commit :broadcast_update
  after_destroy_commit :broadcast_destroy, :broadcast_badges

  # public for db migration
  def creative_snippet
    creative.creative_snippet
  end

  private

  def create_inbox_item(owner, key, params = {})
    InboxItem.create!(
      owner: owner,
      message_key: key,
      message_params: params,
      link: Rails.application.routes.url_helpers.creative_comment_url(
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
    return User.none unless user
    emails = mentioned_emails - [ user.email.downcase ]
    names = mentioned_names - [ user.name.downcase ]
    scope = User.none
    scope = scope.or(User.where(email: emails)) if emails.any?
    scope = scope.or(User.where("LOWER(name) IN (?)", names)) if names.any?
    scope
  end

  def broadcast_create
    return if private?
    broadcast_append_later_to([ creative, :comments ], target: "comments_list")
  end

  def broadcast_update
    return if private?
    broadcast_update_later_to([ creative, :comments ])
  end

  def broadcast_destroy
    return if private?
    broadcast_remove_to([ creative, :comments ])
  end

  def broadcast_badges
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
    self.user ||= Current.user
  end

  def should_apply_link_previews?
    will_save_change_to_content? && content.present?
  end

  def apply_link_previews
    self.content = CommentLinkFormatter.new(content).format
  rescue StandardError => e
    Rails.logger.warn("Comment link preview formatting failed: #{e.class} #{e.message}")
  end

  def self.broadcast_badges(creative)
    origin = creative.effective_origin
    users = [ origin.user ].compact + origin.all_shared_users(:feedback).map(&:user)
    users.compact!
    users.uniq!
    users.each do |u|
      broadcast_badge(origin, u)
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

class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true

  before_validation :assign_default_user, on: :create

  validates :content, presence: true

  after_create_commit :broadcast_create, :notify_write_users, :notify_mentions
  after_update_commit :broadcast_update
  after_destroy_commit :broadcast_destroy

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

  def mentioned_users
    return [] unless user
    emails = mentioned_emails - [ user.email.downcase ]
    User.where(email: emails)
  end

  def broadcast_create
    broadcast_append_later_to([ creative, :comments ], target: "comments_list")
  end

  def broadcast_update
    broadcast_replace_later_to([ creative, :comments ])
  end

  def broadcast_destroy
    broadcast_remove_to([ creative, :comments ])
  end

  def notify_write_users
    return unless user
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
        { user: user.display_name, comment: content }
      )
    end
  end

  def notify_mentions
    mentioned_users.each do |mentioned|
      create_inbox_item(
        mentioned,
        "inbox.user_mentioned",
        { user: user.display_name, comment: content }
      )
    end
  end

  def assign_default_user
    self.user ||= Current.user
  end
end

class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true

  before_validation :assign_default_user, on: :create

  validates :content, presence: true

  after_create_commit :broadcast_create, :notify_creative_owner, :notify_mentions
  after_update_commit :broadcast_update
  after_destroy_commit :broadcast_destroy

  private

  def create_inbox_item(owner, message)
    InboxItem.create!(
      owner: owner,
      message: message,
      link: Rails.application.routes.url_helpers.creative_comment_path(creative, self)
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
    broadcast_prepend_later_to([ creative, :comments ], target: "comments_list")
  end

  def broadcast_update
    broadcast_replace_later_to([ creative, :comments ])
  end

  def broadcast_destroy
    broadcast_remove_to([ creative, :comments ])
  end

  def notify_creative_owner
    return unless creative.user && user && creative.user != user
    create_inbox_item(
      creative.user,
      I18n.t("inbox.comment_added", user: user.email, comment: content)
    )
  end

  def notify_mentions
    mentioned_users.each do |mentioned|
      create_inbox_item(
        mentioned,
        I18n.t("inbox.user_mentioned", user: user.email, comment: content)
      )
    end
  end

  def assign_default_user
    self.user ||= Current.user
  end
end

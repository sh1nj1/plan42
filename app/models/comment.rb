class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true
  has_many :comment_reads, dependent: :destroy

  before_validation :assign_default_user, on: :create

  validates :content, presence: true

  after_create_commit :broadcast_create, :notify_creative_owner, :notify_mentions, :initialize_comment_reads
  after_update_commit :broadcast_update
  after_destroy_commit :broadcast_destroy

  private

  def create_inbox_item(owner, message)
    InboxItem.create!(
      owner: owner,
      message: message,
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

  def initialize_comment_reads
    origin = creative.effective_origin
    user_ids = [ origin.user_id, user_id ]
    user_ids += origin.creative_shares.where(permission: %i[feedback write]).pluck(:user_id)
    user_ids.compact.uniq.each do |uid|
      CommentRead.create!(comment: self, user_id: uid, read: uid == user_id)
    end
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

  public

  def read_by?(user)
    comment_reads.exists?(user: user, read: true)
  end

  def unread_by?(user)
    !read_by?(user)
  end
end

class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true

  validates :content, presence: true

  after_create_commit :broadcast_create, :notify_creative_owner, :notify_mentions
  after_update_commit :broadcast_update
  after_destroy_commit :broadcast_destroy

  private

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

    InboxItem.create!(
      owner: creative.user,
      message: I18n.t("inbox.comment_added", user: user.email, comment: content),
      link: Rails.application.routes.url_helpers.creative_comment_path(creative, self)
    )
  end

  def notify_mentions
    return unless user
    emails = content.scan(/@([\w.\-+]+@[a-zA-Z0-9\-.]+\.[a-zA-Z]{2,})/).flatten
    emails.each do |email|
      mentioned = User.find_by(email: email.downcase)
      next unless mentioned && mentioned != user
      InboxItem.create!(
        owner: mentioned,
        message: I18n.t("inbox.user_mentioned", user: user.email, comment: content),
        link: Rails.application.routes.url_helpers.creative_comment_path(creative, self)
      )
    end
  end
end

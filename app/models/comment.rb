class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true

  validates :content, presence: true

  after_create_commit :notify_creative_owner

  private

  def notify_creative_owner
    return unless creative.user && user && creative.user != user

    InboxItem.create!(
      owner: creative.user,
      message: I18n.t('inbox.comment_added', user: user.email, comment: content),
      link: Rails.application.routes.url_helpers.creative_path(creative)
    )
  end
end

class CreativeShare < ApplicationRecord
  belongs_to :creative
  belongs_to :user

  enum :permission, {
    read: 0,
    feedback: 1,
    write: 2
  }

  validates :creative_id, presence: true
  validates :user_id, presence: true
  validates :permission, presence: true
  validates :user_id, uniqueness: { scope: :creative_id }

  after_create_commit :notify_recipient

  private

  def notify_recipient
    return unless Current.user && user
    desc = creative.effective_description
    title = ActionController::Base.helpers.strip_tags(desc)
    short_title = ActionController::Base.helpers.truncate(title, length: 30)
    InboxItem.create!(
      owner: user,
      message: I18n.t("inbox.creative_shared", user: Current.user.email, short_title: short_title),
      link: Rails.application.routes.url_helpers.creative_url(
        creative,
        Rails.application.config.action_mailer.default_url_options
      )
    )
  end

  def linked_creative_exists?
    Creative.exists?(origin_id: creative.id, user_id: user.id)
  end
end

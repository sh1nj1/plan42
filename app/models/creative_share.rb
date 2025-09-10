class CreativeShare < ApplicationRecord
  belongs_to :creative
  belongs_to :user

  enum :permission, {
    no_access: 0,
    read: 1,
    feedback: 2,
    write: 3,
    admin: 4
  }

  validates :creative_id, presence: true
  validates :user_id, presence: true
  validates :permission, presence: true
  validates :user_id, uniqueness: { scope: :creative_id }

  after_create_commit :notify_recipient, unless: :no_access?

  # Given ancestor_ids and ancestor_shares, returns the closest CreativeShare
  # in the ancestors. If there is no ancestor share, returns nil.
  def self.closest_parent_share(ancestor_ids, ancestor_shares)
    ancestor_shares.to_a.min_by { |s| ancestor_ids.index(s.creative_id) || Float::INFINITY }
  end

  private

  def notify_recipient
    return unless Current.user && user
    desc = creative.effective_description
    title = ActionController::Base.helpers.strip_tags(desc)
    short_title = ActionController::Base.helpers.truncate(title, length: 30)
    InboxItem.create!(
      owner: user,
      message_key: "inbox.creative_shared",
      message_params: { user: Current.user.display_name, short_title: short_title },
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

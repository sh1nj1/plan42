class InboxItem < ApplicationRecord
  belongs_to :owner, class_name: "User"

  after_commit :broadcast_badge_update, on: %i[create update destroy] # adjust callbacks as needed
  after_create_commit :enqueue_push_notification

  attribute :state, :string, default: "new"
  validates :state, inclusion: { in: %w[new read archived] }
  validates :message_key, presence: true

  scope :new_items, -> { where(state: "new") }
  scope :read_items, -> { where(state: "read") }


  def read?
    state == "read"
  end

  def localized_message(locale: I18n.locale)
    if message_key.present?
      params = message_params || {}
      I18n.t(message_key, **params.symbolize_keys, locale: locale)
    else
      message
    end
  end

  private

  def broadcast_badge_update
    # Recompute the new count for this owner:
    new_count = InboxItem.where(owner: owner, state: "new").count

      # Use Turbo::StreamsChannel to broadcast replace to that user’s inbox stream:
      %w[desktop-inbox-badge mobile-inbox-badge].each do |target_id|
        Turbo::StreamsChannel.broadcast_replace_to(
          [ "inbox", owner ],
          target: target_id,
          partial: "inbox/badge_component/count",
          locals: { count: new_count, badge_id: target_id, show_zero: false }
        )
      end
  end

  def enqueue_push_notification
    msg = localized_message(locale: owner.locale || "en")
    PushNotificationJob.perform_later(owner_id, message: msg, link: link)
  end
end

class InboxItem < ApplicationRecord
  INTERPOLATION_PATTERN = /%%|%\{([\w|]+)\}|%<(\w+)>[^\d]*?\d*\.?\d*[bBdiouxXeEfgGcps]/.freeze

  belongs_to :owner, class_name: "User"
  belongs_to :comment, optional: true
  belongs_to :creative, optional: true

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
    msg =
      if message_key.present?
        params = message_params || {}
        translate_message(message_key, params.symbolize_keys, locale: locale)
      else
        message
      end

    msg&.gsub("&nbsp;", " ")&.gsub("\u00A0", " ")
  end

  private

  def translate_message(message_key, params, locale:)
    I18n.t(message_key, **params, locale: locale)
  rescue I18n::MissingInterpolationArgument => e
    missing_keys = extract_missing_keys(e.string, params)
    fallback_params =
      missing_keys.index_with do |missing_key|
        default_interpolation_value(missing_key, locale: locale)
      end

    I18n.t(message_key, **params.merge(fallback_params), locale: locale)
  end

  def extract_missing_keys(translation_string, params)
    interpolations =
      translation_string.to_s.scan(INTERPOLATION_PATTERN).map do |match|
        match.compact.first&.to_sym
      end

    interpolations.compact.uniq - params.keys
  end

  def default_interpolation_value(key, locale:)
    case key.to_sym
    when :comment_content
      I18n.t("inbox.comment_content_unavailable", locale: locale, default: "")
    else
      ""
    end
  end

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

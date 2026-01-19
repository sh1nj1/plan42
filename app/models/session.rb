class Session < ApplicationRecord
  belongs_to :user

  def expired?
    return false unless SystemSetting.session_timeout_enabled?
    return true if last_active_at.nil?

    last_active_at < SystemSetting.session_timeout.ago
  end

  def touch_activity!
    update_column(:last_active_at, Time.current) if should_touch_activity?
  end

  private

  def should_touch_activity?
    # Only update if last_active_at is nil or older than 1 minute (avoid too frequent updates)
    last_active_at.nil? || last_active_at < 1.minute.ago
  end
end

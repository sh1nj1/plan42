module Collavre
  class Session < ApplicationRecord
    self.table_name = "sessions"

    belongs_to :user, class_name: "Collavre::User"

    def expired?
      return false unless Collavre::SystemSetting.session_timeout_enabled?
      return true if last_active_at.nil?

      last_active_at < Collavre::SystemSetting.session_timeout.ago
    end

    def touch_activity!
      update_column(:last_active_at, Time.current) if should_touch_activity?
    end

    private

    def should_touch_activity?
      last_active_at.nil? || last_active_at < 1.minute.ago
    end
  end
end

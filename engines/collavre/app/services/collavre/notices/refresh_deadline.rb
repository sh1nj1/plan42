module Collavre
  module Notices
    # A single refresh schedule for initial pages, HTTP feeds and broadcasts.
    # Include future windows even when their notices are not currently visible.
    module RefreshDeadline
      def self.for(user, now: Time.current)
        return unless user

        boundaries = NoticeRegistry.all.flat_map { |notice| [ notice.starts_at, notice.ends_at ] }
        boundaries << UserNotice.where(user: user).snoozed.where("snoozed_until > ?", now).minimum(:snoozed_until)
        boundaries.compact.select { |time| time > now }.min
      end
    end
  end
end

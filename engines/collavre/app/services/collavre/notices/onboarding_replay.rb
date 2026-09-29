module Collavre
  module Notices
    # An explicit user-requested restart is the sole exception to terminal
    # completion. Seed every step as pending so Feed does not backfill it from
    # historical activity on the next render.
    class OnboardingReplay
      def self.call(user)
        rows = NoticeRegistry.group(:onboarding).select(&:mission?).map do |notice|
          { user_id: user.id, notice_key: notice.key.to_s, status: "pending",
            snoozed_until: nil, completed_at: nil }
        end
        UserNotice.upsert_all(rows, unique_by: %i[user_id notice_key]) if rows.any?
      end
    end
  end
end

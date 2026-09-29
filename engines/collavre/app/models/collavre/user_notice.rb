module Collavre
  # A user's progress through one registered notice (see Collavre::NoticeRegistry).
  # The notice copy and rules live in code; this row only records what the user
  # did with it. A missing row means the notice is still pending.
  class UserNotice < ApplicationRecord
    self.table_name = "user_notices"

    SNOOZE_DURATION = 1.day

    belongs_to :user, class_name: Collavre.configuration.user_class_name

    enum :status, { pending: "pending", snoozed: "snoozed", dismissed: "dismissed", completed: "completed" },
         validate: true

    # One row per user and key is enforced by the unique index; record! retries
    # the race instead of pre-checking with a validation query.
    validates :notice_key, presence: true

    # Finished rows never show again; a snooze hides the notice until it lapses.
    def hidden?(now = Time.current)
      dismissed? || completed? || (snoozed? && snoozed_until.present? && snoozed_until > now)
    end

    def self.for(user, key)
      find_or_initialize_by(user: user, notice_key: key.to_s)
    end

    def self.record!(user, key, status, snoozed_until: nil)
      notice = self.for(user, key)
      notice.update!(status: status, snoozed_until: snoozed_until,
                     completed_at: status.to_s == "completed" ? Time.current : nil)
      notice
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end

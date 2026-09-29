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

    # One row per user and key is enforced by the unique index; seed! resolves
    # the insert race instead of pre-checking with a validation query.
    validates :notice_key, presence: true

    # Finished rows never show again; a snooze hides the notice until it lapses.
    def hidden?(now = Time.current)
      dismissed? || completed? || (snoozed? && snoozed_until.present? && snoozed_until > now)
    end

    # Completion is final: a stale snooze or dismissal (e.g. from a sheet left
    # open while the mission finished in another tab) must not reopen it. The
    # guard lives in the UPDATE itself, so a completion committed between our
    # read and write still wins.
    def self.record!(user, key, status, snoozed_until: nil)
      notice = seed!(user, key, status, snoozed_until: snoozed_until)
      return notice if notice.previously_new_record?

      rows = where(id: notice.id).where.not(status: "completed")
      rows.update_all(status: status.to_s, snoozed_until: snoozed_until,
                      completed_at: completed_at_for(status), updated_at: Time.current)
      notice.reload
    end

    # Returns true only for the request that inserts or transitions the row.
    # The conditional UPDATE arbitrates overlapping events in the database.
    def self.complete!(user, key)
      notice = seed!(user, key, :completed)
      return true if notice.previously_new_record?

      where(id: notice.id, status: %w[pending snoozed]).update_all(
        status: "completed", snoozed_until: nil, completed_at: Time.current, updated_at: Time.current
      ) == 1
    end

    # Writes the initial state only when the user has no row yet; a row that
    # appeared meanwhile (e.g. an event completing the mission) wins.
    def self.seed!(user, key, status, snoozed_until: nil)
      create_or_find_by!(user: user, notice_key: key.to_s) do |notice|
        notice.status = status
        notice.snoozed_until = snoozed_until
        notice.completed_at = completed_at_for(status)
      end
    end

    def self.completed_at_for(status)
      Time.current if status.to_s == "completed"
    end
    private_class_method :completed_at_for
  end
end

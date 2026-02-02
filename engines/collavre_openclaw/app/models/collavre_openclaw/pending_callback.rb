module CollavreOpenclaw
  class PendingCallback < ApplicationRecord
    self.table_name = "openclaw_pending_callbacks"

    belongs_to :openclaw_account, class_name: "CollavreOpenclaw::OpenclawAccount"

    # Serialize context as JSON for SQLite compatibility
    serialize :context, coder: JSON

    validates :nonce, presence: true, uniqueness: true
    validates :expires_at, presence: true

    scope :valid, -> { where("expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }

    # Default expiration time (7 days to support scheduled callbacks like cron jobs)
    EXPIRATION_TIME = 7.days

    # Generate a new pending callback for a request
    def self.create_for_request(account:, creative_id: nil, comment_id: nil, thread_id: nil, context: {})
      create!(
        openclaw_account: account,
        nonce: generate_nonce,
        creative_id: creative_id,
        comment_id: comment_id,
        thread_id: thread_id,
        context: context || {},
        expires_at: EXPIRATION_TIME.from_now
      )
    end

    # Verify and consume a nonce (one-time use)
    def self.verify_and_consume!(nonce)
      callback = valid.find_by(nonce: nonce)
      return nil unless callback

      # Consume the nonce (delete it)
      callback.destroy!
      callback
    end

    # Cleanup expired callbacks
    def self.cleanup_expired!
      expired.delete_all
    end

    private

    def self.generate_nonce
      SecureRandom.urlsafe_base64(32)
    end
  end
end

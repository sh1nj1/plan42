module CollavreTranslation
  class Translation < Collavre::ApplicationRecord
    CLAIM_TIMEOUT = 5.minutes

    belongs_to :translatable, polymorphic: true
    validates :target_locale, inclusion: { in: %w[en ko] }
    validates :status, inclusion: { in: %w[pending processing translating completed skipped failed] }
    validates :source_digest, presence: true

    def stale_claim?
      status == "translating" && updated_at < CLAIM_TIMEOUT.ago
    end

    def self.digest(content)
      Digest::SHA256.hexdigest(content.to_s)
    end

    def self.for_comment(comment, locale)
      record = find_by(translatable: comment, target_locale: locale, source_digest: digest(comment.content))
      record&.stale_claim? ? request!(comment, locale) : record
    end

    def self.request!(comment, locale)
      record = create_or_find_by!(translatable: comment, target_locale: locale,
        source_digest: digest(comment.content))
      # A compare-and-swap also recovers an enqueue failure without duplicate jobs.
      claimed = where(id: record.id, status: "pending").or(where(id: record.id, status: "translating")
        .where("updated_at < ?", CLAIM_TIMEOUT.ago)).update_all(status: "processing", updated_at: Time.current)
      if claimed == 1
        begin
          TranslateJob.perform_later(record.id)
        rescue StandardError
          where(id: record.id, status: "processing").update_all(status: "pending", updated_at: Time.current)
          raise
        end
      end
      record.reload
    end
  end
end

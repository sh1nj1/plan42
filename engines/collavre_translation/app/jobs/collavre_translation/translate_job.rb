module CollavreTranslation
  class TranslateJob < ::ApplicationJob
    queue_as :translations

    def perform(id)
      record = Translation.find_by(id: id)
      return unless record && claim(record)
      return update_claim(record, status: "pending") unless CollavreTranslation.enabled?

      translate(record)
    rescue ActiveRecord::RecordNotFound
      owned_claim(record).destroy_all if record && @claimed_at
    rescue StandardError => error
      Rails.logger.warn("Comment translation failed: #{error.class}")
      update_claim(record, status: "failed", content: nil) if record && @claimed_at
    end

    private

    def claim(record)
      @claimed_at = Time.current
      candidates = Translation.where(id: record.id, status: "processing")
        .or(Translation.where(id: record.id, status: "translating")
          .where("updated_at < ?", Translation::CLAIM_TIMEOUT.ago))
      candidates.update_all(status: "translating", updated_at: @claimed_at) == 1
    end

    # updated_at is the lease token; intermediate writes must keep it unchanged.
    # A recovered worker cannot publish or fail a replacement worker's claim.
    def owned_claim(record)
      Translation.where(id: record.id, status: "translating", updated_at: @claimed_at)
    end

    def update_claim(record, **attributes)
      owned_claim(record).update_all(attributes)
    end

    def translate(record)
      comment = record.translatable
      return owned_claim(record).destroy_all unless comment
      return update_claim(record, status: "skipped") unless current_source?(record, comment)

      source_lang = LanguageDetector.detect(comment.content)
      update_claim(record, source_lang: source_lang)
      return update_claim(record, status: "skipped") if source_lang.nil? || source_lang == record.target_locale

      vendor = CollavreTranslation.vendor
      model = CollavreTranslation.model
      content = Translator.call(comment.content, record.target_locale, vendor: vendor, model: model)
      # Never publish a result for a source edited while the provider was running.
      return update_claim(record, status: "skipped") unless current_source?(record, comment.reload)

      update_claim(record, content: content, status: "completed",
        llm_vendor: vendor, llm_model: model)
    end

    def current_source?(record, comment)
      Translation.digest(comment.content) == record.source_digest
    end
  end
end

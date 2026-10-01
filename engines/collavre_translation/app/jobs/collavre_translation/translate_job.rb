module CollavreTranslation
  class TranslateJob < ::ApplicationJob
    queue_as :translations

    def perform(id)
      record = Translation.find_by(id: id)
      return unless record && claim(record)
      return record.update!(status: "skipped") unless CollavreTranslation.enabled?

      translate(record)
    rescue ActiveRecord::RecordNotFound
      record&.destroy
    rescue StandardError => error
      Rails.logger.warn("Comment translation failed: #{error.class}")
      record&.update!(status: "failed", content: nil)
    end

    private

    def claim(record)
      Translation.where(id: record.id, status: "processing")
        .update_all(status: "translating", updated_at: Time.current) == 1
    end

    def translate(record)
      comment = record.translatable
      return record.destroy! unless comment
      return record.update!(status: "skipped") unless current_source?(record, comment)

      source_lang = LanguageDetector.detect(comment.content)
      record.update!(source_lang: source_lang)
      return record.update!(status: "skipped") if source_lang.nil? || source_lang == record.target_locale

      content = Translator.call(comment.content, record.target_locale)
      # Never publish a result for a source edited while the provider was running.
      return record.update!(status: "skipped") unless current_source?(record, comment.reload)

      record.update!(content: content, status: "completed",
        llm_vendor: CollavreTranslation.vendor, llm_model: CollavreTranslation.model)
    end

    def current_source?(record, comment)
      Translation.digest(comment.content) == record.source_digest
    end
  end
end

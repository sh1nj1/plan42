require "collavre_translation/version"
require "collavre_translation/engine"

module CollavreTranslation
  class << self
    attr_writer :vendor, :model

    def vendor
      @vendor || Collavre::IntegrationSettings.fetch(:translation_llm_vendor, default: "google")
    end

    def model
      @model || Collavre::IntegrationSettings.fetch(:translation_llm_model)
    end

    def enabled_for?(user)
      user&.auto_translation_enabled? && enabled?
    end

    def enabled?
      model.present? && %w[google gemini openai anthropic].include?(vendor)
    end
  end
end

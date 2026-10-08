module CollavreTranslation
  module TranslationLocale
    private

    def target_locale
      (params[:lang].presence || Current.user&.locale.presence || I18n.locale).to_s.split(/[-_]/).first
    end
  end
end

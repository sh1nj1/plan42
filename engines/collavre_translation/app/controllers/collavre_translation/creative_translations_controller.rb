module CollavreTranslation
  class CreativeTranslationsController < Collavre::ApplicationController
    include TranslationLocale
    allow_unauthenticated_access
    before_action :load_creative

    def show
      render_translation(Translation.for_creative(@creative, target_locale))
    end

    def create
      render_translation(Translation.request!(@creative.effective_origin, target_locale))
    end

    private

    def load_creative
      @creative = Collavre::Creative.find(params[:creative_id])
      return head(Current.user ? :forbidden : :unauthorized) unless @creative.has_permission?(Current.user, :read)
      return head :forbidden unless @creative.effective_origin.has_permission?(Current.user, :read)

      return head :service_unavailable unless CollavreTranslation.enabled?
      return head :forbidden unless ContentTranslationPolicy.enabled?(@creative.effective_origin, Current.user)

      head :unprocessable_entity unless %w[en ko].include?(target_locale)
    end

    def render_translation(record)
      response.headers["Cache-Control"] = "no-store"
      render json: { status: record&.status || "missing", content: record&.content,
        source_digest: Translation.digest(Translation.source(@creative)),
        original_html: original_html }
    end

    # Workspace tree labels are built from the stored description, so they need
    # the source before YouTube anchors (and their text) become empty iframes.
    def original_html
      source = Translation.source(@creative)
      params[:embed] == "0" ? source : helpers.embed_youtube_iframe(source)
    end
  end
end

module CollavreTranslation
  class TranslationsController < Collavre::ApplicationController
    include Collavre::Comments::CommentScoping
    include TranslationLocale
    allow_unauthenticated_access
    before_action :require_authentication, if: -> { Collavre::SystemSetting.creatives_login_required? }
    before_action :load_comment
    before_action :require_auto_translation
    before_action :validate_locale

    def show
      render_translation(Translation.for_comment(@comment, target_locale))
    end

    def create
      return head :conflict if @comment.task&.status.in?(%w[running pending queued])

      render_translation(Translation.request!(@comment, target_locale))
    end

    private

    def require_auto_translation
      return head :service_unavailable unless CollavreTranslation.enabled?

      head :forbidden unless ContentTranslationPolicy.enabled?(@comment, Current.user)
    end

    def load_comment
      scope = Current.user ? Collavre::Comment.visible_to(Current.user) : Collavre::Comment.public_only
      comment = scope.find(params[:comment_id])
      if !Current.user && !comment.creative.has_permission?(nil, :read)
        return head :unauthorized
      end
      params[:creative_id] = comment.creative_id
      set_creative
      return if performed?

      @comment = comment
    end

    def validate_locale
      head :unprocessable_entity unless %w[en ko].include?(target_locale)
    end

    def render_translation(record)
      response.headers["Cache-Control"] = "no-store"
      render json: { status: record&.status || "missing", content: record&.content,
        source_digest: Translation.digest(@comment.content) }
    end
  end
end

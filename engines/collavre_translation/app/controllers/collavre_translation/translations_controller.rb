module CollavreTranslation
  class TranslationsController < Collavre::ApplicationController
    include Collavre::Comments::CommentScoping
    before_action :require_translation_user
    before_action :load_comment
    before_action :validate_locale

    def show
      render_translation(Translation.for_comment(@comment, target_locale))
    end

    def create
      return head :service_unavailable unless CollavreTranslation.enabled?
      return head :conflict if @comment.task&.status.in?(%w[running pending queued])

      render_translation(Translation.request!(@comment, target_locale))
    end

    private

    def require_translation_user
      head :unauthorized unless Current.user
    end

    def load_comment
      comment = Collavre::Comment.visible_to(Current.user).find(params[:comment_id])
      params[:creative_id] = comment.creative_id
      set_creative
      return if performed?

      @comment = comment
    end

    def validate_locale
      head :unprocessable_entity unless %w[en ko].include?(target_locale)
    end

    def target_locale
      Current.user.locale.to_s.split(/[-_]/).first.presence || I18n.default_locale.to_s
    end

    def render_translation(record)
      response.headers["Cache-Control"] = "no-store"
      render json: { status: record&.status || "missing", content: record&.content,
        source_digest: Translation.digest(@comment.content) }
    end
  end
end

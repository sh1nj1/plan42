# frozen_string_literal: true

module Collavre
  module CreativePermissionGuard
    extend ActiveSupport::Concern

    private

    def require_creative_read!
      return if @creative.has_permission?(Current.user, :read) || @creative.user == Current.user

      render json: { error: creative_permission_denied_message }, status: :forbidden
    end

    def require_creative_write!
      return if @creative.has_permission?(Current.user, :write) || @creative.user == Current.user

      render json: { error: creative_permission_denied_message }, status: :forbidden
    end

    def require_creative_admin!
      return if @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user

      render json: { error: creative_permission_denied_message }, status: :forbidden
    end

    # Override in controllers that use a different i18n key.
    def creative_permission_denied_message
      I18n.t("collavre.topics.no_permission")
    end
  end
end

# frozen_string_literal: true

module Collavre
  module IntegrationPermission
    extend ActiveSupport::Concern

    private

    def ensure_read_permission
      return if @creative.has_permission?(Current.user, :read)

      render json: { error: integration_forbidden_message }, status: :forbidden
    end

    def ensure_admin_permission
      return if @creative.has_permission?(Current.user, :admin)

      render json: { error: integration_forbidden_message }, status: :forbidden
    end

    def ensure_write_permission
      return if @creative.has_permission?(Current.user, :write)

      render json: { error: integration_forbidden_message }, status: :forbidden
    end

    def integration_forbidden_message
      "forbidden"
    end
  end
end

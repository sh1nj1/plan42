# frozen_string_literal: true

module Collavre
  module ProxyErrorResponse
    extend ActiveSupport::Concern

    private

    def render_proxy_error(error)
      status = error.status.to_i.between?(400, 599) ? error.status : :bad_gateway
      render json: { error: { message: error.message, code: error.code } }, status: status
    end
  end
end

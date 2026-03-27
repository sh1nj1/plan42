module CollavreOpenclaw
  class HealthController < ApplicationController
    allow_unauthenticated_access only: :show

    def show
      payload = {
        status: "ok",
        engine: "collavre_openclaw",
        version: CollavreOpenclaw::VERSION
      }

      # WebSocket details only for authenticated requests
      if authenticated?
        payload[:transport] = CollavreOpenclaw.config.transport
        payload[:websocket] = ConnectionManager.status_summary
        payload[:reactor] = { running: EmReactor.running? }
      end

      render json: payload
    end

    private

    def authenticated?
      respond_to?(:current_user, true) && current_user.present?
    rescue
      false
    end
  end
end

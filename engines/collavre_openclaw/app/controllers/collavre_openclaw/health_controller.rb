module CollavreOpenclaw
  class HealthController < ApplicationController
    allow_unauthenticated_access only: :show

    def show
      ws_status = if ConnectionManager.instance_variable_get(:@singleton__instance__)
                    ConnectionManager.instance.status
      else
                    { total_connections: 0, total_users: 0,
                      connected: 0, connecting: 0, reconnecting: 0, disconnected: 0 }
      end

      render json: {
        status: "ok",
        engine: "collavre_openclaw",
        version: CollavreOpenclaw::VERSION,
        transport: CollavreOpenclaw.config.transport,
        websocket: ws_status,
        reactor: { running: EmReactor.running? }
      }
    end
  end
end

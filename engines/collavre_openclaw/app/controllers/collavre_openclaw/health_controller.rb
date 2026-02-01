module CollavreOpenclaw
  class HealthController < ApplicationController
    allow_unauthenticated_access only: :show

    def show
      render json: {
        status: "ok",
        engine: "collavre_openclaw",
        version: CollavreOpenclaw::VERSION
      }
    end
  end
end

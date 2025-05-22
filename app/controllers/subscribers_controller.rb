class SubscribersController < ApplicationController
    allow_unauthenticated_access
    before_action :set_creative

    def create
      @creative.subscribers.where(subscriber_params).first_or_create
      redirect_to @creative, notice: "You are now subscribed."
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id])
    end

    def subscriber_params
      params.require(:subscriber).permit(:email)
    end
end

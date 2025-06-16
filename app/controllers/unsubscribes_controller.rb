class UnsubscribesController < ApplicationController
    allow_unauthenticated_access
    before_action :set_subscriber

    def show
      @subscriber&.destroy
      redirect_to root_path, notice: t("subscribers.unsubscribed")
    end

    private

    def set_subscriber
      @subscriber = Subscriber.find_by_token_for(:unsubscribe, params[:token])
    end
end

module Collavre
  class ChannelsController < ApplicationController
    before_action :set_channel

    def destroy
      @channel.detach!
      head :no_content
    end

    private

    def set_channel
      @channel = Channel.active.find(params[:id])
    end
  end
end

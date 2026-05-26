module Collavre
  class ChannelsController < ApplicationController
    include Collavre::CreativePermissionGuard

    before_action :set_channel
    before_action :require_creative_write!

    def destroy
      @channel.detach!
      head :no_content
    end

    private

    def set_channel
      @channel = Channel.active.find(params[:id])
      @creative = @channel.topic.creative.effective_origin
    end
  end
end

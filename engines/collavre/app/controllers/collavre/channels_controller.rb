module Collavre
  class ChannelsController < ApplicationController
    include Collavre::CreativePermissionGuard

    before_action :set_channel
    before_action :require_creative_write!

    def destroy
      @channel.dismiss!
      head :no_content
    end

    private

    def set_channel
      # Look up among not-yet-dismissed channels (active OR detached). The X
      # button must work on detached chips too — those linger so the user can
      # still see the final merge/close badge until they choose to clear it.
      @channel = Channel.not_dismissed.find(params[:id])
      @creative = @channel.topic.creative.effective_origin
    end
  end
end

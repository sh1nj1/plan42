module CollavreSlack
  class SlackMessagesController < ApplicationController
    before_action :set_creative

    def create
      unless @creative.has_permission?(Current.user, :feedback)
        render json: { error: I18n.t("collavre_slack.errors.forbidden") }, status: :forbidden
        return
      end

      channel_link = SlackChannelLink.find_by!(creative: @creative)
      dispatcher = SlackMessageDispatcher.new(channel_link: channel_link)
      log = dispatcher.enqueue(message: params[:message], sender: Current.user)

      render json: { status: "queued", message_log_id: log.id }, status: :accepted
    end

    private

    def set_creative
      @creative = Collavre::Creative.find(params[:creative_id])
    end
  end
end

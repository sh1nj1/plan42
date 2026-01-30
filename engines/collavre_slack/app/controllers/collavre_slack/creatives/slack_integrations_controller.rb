module CollavreSlack
  module Creatives
    class SlackIntegrationsController < ApplicationController
      before_action :set_creative

      def index
        @links = SlackChannelLink.where(creative: @creative, is_active: true)
        respond_to do |format|
          format.json { render json: @links }
          format.html
        end
      end

      def create
        unless @creative.has_permission?(Current.user, :feedback)
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        slack_account = SlackAccount.find(params[:slack_account_id])
        service = SlackIntegrationService.new(user: Current.user, slack_account: slack_account)
        link = service.link_channel(creative: @creative, channel_id: params[:channel_id], channel_name: params[:channel_name])
        render json: link, status: :created
      end

      def destroy
        link = SlackChannelLink.find(params[:id])
        unless link.creative == @creative
          render json: { error: "Not found" }, status: :not_found
          return
        end

        unless @creative.has_permission?(Current.user, :feedback)
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        SlackIntegrationService.new(user: Current.user, slack_account: link.slack_account).unlink_channel(link)
        head :no_content
      end

      private

      def set_creative
        @creative = Collavre::Creative.find(params[:creative_id])
      end
    end
  end
end

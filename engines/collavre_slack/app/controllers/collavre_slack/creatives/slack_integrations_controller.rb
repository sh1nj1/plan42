module CollavreSlack
  module Creatives
    class SlackIntegrationsController < ApplicationController
      before_action :set_creative

      def index
        # Always use origin creative for Slack links (chat messages are on origin)
        target_creative = @creative.effective_origin
        @links = SlackChannelLink.where(creative: target_creative)
        respond_to do |format|
          format.json do
            slack_account = Current.user ? SlackAccount.find_by(user: Current.user) : nil
            channels = slack_account ? fetch_channels(slack_account) : []

            render json: {
              connected: slack_account.present?,
              channels: channels,
              links: @links.map { |link|
                {
                  id: link.id,
                  channel_id: link.channel_id,
                  channel_name: link.channel_name,
                  last_synced_at: link.last_synced_at
                }
              }
            }
          end
          format.html
        end
      end

      def create
        unless @creative.has_permission?(Current.user, :feedback)
          render json: { success: false, error: I18n.t("collavre_slack.errors.forbidden") }, status: :forbidden
          return
        end

        # Find the user's Slack account
        slack_account = if params[:slack_account_id].present?
          SlackAccount.find(params[:slack_account_id])
        else
          SlackAccount.find_by(user: Current.user)
        end

        unless slack_account
          render json: { success: false, error: I18n.t("collavre_slack.errors.no_slack_account") }, status: :unprocessable_entity
          return
        end

        # Always link to origin creative (chat messages are on origin)
        target_creative = @creative.effective_origin

        service = SlackIntegrationService.new(user: Current.user, slack_account: slack_account)
        link = service.link_channel(creative: target_creative, channel_id: params[:channel_id], channel_name: params[:channel_name])

        if link.persisted?
          render json: { success: true, link: { id: link.id, channel_id: link.channel_id, channel_name: link.channel_name } }, status: :created
        else
          render json: { success: false, error: link.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      # Lightweight endpoint for badge display — returns only existing links, no Slack API calls
      def badge
        target_creative = @creative.effective_origin
        links = SlackChannelLink.where(creative: target_creative)
        render json: {
          links: links.map { |link|
            { channel_name: link.channel_name }
          }
        }
      end

      def destroy
        link = SlackChannelLink.find(params[:id])
        # Check against origin creative
        target_creative = @creative.effective_origin
        unless link.creative_id == target_creative.id
          render json: { success: false, error: I18n.t("collavre_slack.errors.not_found") }, status: :not_found
          return
        end

        unless @creative.has_permission?(Current.user, :feedback)
          render json: { success: false, error: I18n.t("collavre_slack.errors.forbidden") }, status: :forbidden
          return
        end

        SlackIntegrationService.new(user: Current.user, slack_account: link.slack_account).unlink_channel(link)
        render json: { success: true }
      end

      private

      def set_creative
        @creative = Collavre::Creative.find(params[:creative_id])
      end

      def fetch_channels(slack_account)
        client = SlackClient.new(access_token: slack_account.access_token)
        client.list_all_channels.map do |channel|
          { id: channel[:id], name: channel[:name] }
        end
      rescue StandardError => e
        Rails.logger.error("Failed to fetch Slack channels: #{e.message}")
        []
      end
    end
  end
end

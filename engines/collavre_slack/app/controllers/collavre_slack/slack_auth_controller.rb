module CollavreSlack
  class SlackAuthController < ApplicationController
    allow_unauthenticated_access only: :callback

    def start
      unless Current.user
        render json: { error: "Authentication required" }, status: :unauthorized
        return
      end

      redirect_to slack_client.oauth_authorize_url(state: oauth_state)
    end

    def callback
      if params[:state].present? && params[:state] != session[:slack_oauth_state]
        render json: { error: "Invalid OAuth state" }, status: :unprocessable_entity
        return
      end

      unless params[:code].present?
        render json: { error: "Missing OAuth code" }, status: :unprocessable_entity
        return
      end

      oauth_response = slack_client.oauth_access(code: params[:code], redirect_uri: slack_client.redirect_uri)
      if oauth_response[:ok] != true
        render json: { error: oauth_response[:error] || "Slack OAuth failed" }, status: :unprocessable_entity
        return
      end

      account = SlackAccount.find_or_initialize_by(team_id: oauth_response.dig(:team, :id))
      account.user ||= Current.user
      account.team_name = oauth_response.dig(:team, :name)
      account.access_token = oauth_response[:access_token]
      account.authed_user_id = oauth_response.dig(:authed_user, :id)
      account.scopes = oauth_response[:scope]
      account.save!

      render json: { status: "connected", slack_account_id: account.id }
    end

    private

    def slack_client
      @slack_client ||= SlackClient.new
    end

    def oauth_state
      session[:slack_oauth_state] ||= SecureRandom.hex(16)
    end
  end
end

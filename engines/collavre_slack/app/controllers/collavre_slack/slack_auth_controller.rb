module CollavreSlack
  class SlackAuthController < ApplicationController
    allow_unauthenticated_access only: :callback

    def start
      unless Current.user
        render json: { error: I18n.t("collavre_slack.errors.authentication_required") }, status: :unauthorized
        return
      end

      # Sign the state with user_id to recover it securely in callback (popup windows don't share session)
      state_data = { nonce: SecureRandom.hex(16), user_id: Current.user.id, exp: 10.minutes.from_now.to_i }
      state = message_verifier.generate(state_data)
      session[:slack_oauth_state] = state

      redirect_to slack_client.oauth_authorize_url(state: state), allow_other_host: true
    end

    def callback
      unless params[:code].present?
        render json: { error: I18n.t("collavre_slack.errors.missing_oauth_code") }, status: :unprocessable_entity
        return
      end

      # Verify and decode user_id from signed state (required - popup windows don't share session)
      unless params[:state].present?
        render json: { error: I18n.t("collavre_slack.errors.missing_oauth_state") }, status: :unprocessable_entity
        return
      end

      begin
        state_data = message_verifier.verify(params[:state]).with_indifferent_access
        Rails.logger.info("[SlackAuth] State verified successfully")
        # Check expiration
        if state_data[:exp] && Time.at(state_data[:exp]) < Time.current
          render json: { error: I18n.t("collavre_slack.errors.invalid_oauth_state") }, status: :unprocessable_entity
          return
        end
        user = ::User.find(state_data[:user_id])
        Rails.logger.info("[SlackAuth] User resolved from signed state")
      rescue ActiveSupport::MessageVerifier::InvalidSignature => e
        Rails.logger.warn("[SlackAuth] Invalid state signature: #{e.message}")
        render json: { error: I18n.t("collavre_slack.errors.invalid_oauth_state") }, status: :unprocessable_entity
        return
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn("[SlackAuth] User not found from state")
        render json: { error: I18n.t("collavre_slack.errors.user_not_found") }, status: :unprocessable_entity
        return
      end

      oauth_response = slack_client.oauth_access(code: params[:code], redirect_uri: slack_client.redirect_uri)
      if oauth_response[:ok] != true
        render json: { error: oauth_response[:error] || I18n.t("collavre_slack.errors.oauth_failed") }, status: :unprocessable_entity
        return
      end

      Rails.logger.info("[SlackAuth] OAuth exchange successful")

      account = SlackAccount.find_or_initialize_by(team_id: oauth_response.dig(:team, :id))
      account.user ||= user
      account.team_name = oauth_response.dig(:team, :name)
      account.access_token = oauth_response[:access_token]
      account.authed_user_id = oauth_response.dig(:authed_user, :id)
      account.scopes = oauth_response[:scope]

      if account.save
        # Render HTML that closes the popup and notifies the parent window
        render template: "collavre_slack/slack_auth/callback_success", layout: false
      else
        Rails.logger.error("[SlackAuth] Failed to save account: #{account.errors.full_messages.join(', ')}")
        render json: { error: I18n.t("collavre_slack.errors.save_failed", errors: account.errors.full_messages.join(", ")) }, status: :unprocessable_entity
      end
    end

    private

    def slack_client
      @slack_client ||= SlackClient.new
    end

    def message_verifier
      @message_verifier ||= Rails.application.message_verifier("slack_oauth")
    end
  end
end

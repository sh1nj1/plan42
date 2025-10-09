class NotionAuthController < ApplicationController
  def authorize
    unless Current.user
      render plain: "Unauthorized", status: :unauthorized
      return
    end

    client_id = Rails.application.credentials.dig(:notion, :client_id) || ENV["NOTION_CLIENT_ID"]
    unless client_id.present?
      render plain: "Notion integration not configured", status: :internal_server_error
      return
    end

    redirect_uri = notion_callback_url
    state = generate_state_token
    session[:notion_oauth_state] = state

    authorize_url = "https://api.notion.com/v1/oauth/authorize?" + {
      client_id: client_id,
      response_type: "code",
      owner: "user",
      redirect_uri: redirect_uri,
      state: state
    }.to_query

    redirect_to authorize_url, allow_other_host: true
  end

  def callback
    unless Current.user
      render plain: "Unauthorized", status: :unauthorized
      return
    end

    state_verified = false

    stored_state = session[:notion_oauth_state]
    provided_state = params[:state]

    if stored_state.blank? || provided_state.blank?
      render plain: "Invalid state parameter", status: :unprocessable_entity
      return
    end

    stored_state = stored_state.to_s
    provided_state = provided_state.to_s

    unless stored_state.bytesize == provided_state.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(provided_state, stored_state)
      render plain: "Invalid state parameter", status: :unprocessable_entity
      return
    end

    state_verified = true

    begin
      unless params[:code].present?
        render plain: "Authorization code missing", status: :unprocessable_entity
        return
      end

      Rails.logger.info("Notion OAuth: Starting token exchange for user #{Current.user.id}")

      # Exchange code for token
      token_response = exchange_code_for_token(params[:code])
      Rails.logger.info("Notion OAuth: Token exchange successful, access_token present: #{token_response["access_token"].present?}")

      user_info = fetch_user_info(token_response["access_token"])
      owner_info = user_info.dig("bot", "owner") || {}
      owner_type = owner_info["type"]
      owner_identifier =
        case owner_type
        when "workspace"
          user_info["workspace_id"]
        when "user"
          owner_info.dig("user", "id")
        else
          nil
        end

      Rails.logger.info(
        "Notion OAuth: User info fetched - workspace: #{user_info["workspace_name"]}, " \
        "owner_type: #{owner_type}, owner_identifier: #{owner_identifier}"
      )

      if owner_identifier.blank?
        raise "Unable to determine Notion owner identifier from response"
      end

      # Create or update Notion account
      account = Current.user.notion_account || Current.user.build_notion_account
      account.notion_uid = owner_identifier
      account.workspace_name = user_info["workspace_name"]
      account.workspace_id = user_info["workspace_id"]
      account.bot_id = user_info.dig("bot", "id") || owner_identifier
      account.token = token_response["access_token"]
      account.save!

      Rails.logger.info("Notion OAuth: Account saved successfully for user #{Current.user.id}")
      render plain: "Success! You can close this window.", status: :ok
    rescue => e
      Rails.logger.error("Notion auth callback failed: #{e.class} #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render plain: "Authentication failed: #{e.message}", status: :internal_server_error
    ensure
      session.delete(:notion_oauth_state) if state_verified
    end
  end

  private

  def generate_state_token
    SecureRandom.hex(16)
  end

  def exchange_code_for_token(code)
    client_id = Rails.application.credentials.dig(:notion, :client_id) || ENV["NOTION_CLIENT_ID"]
    client_secret = Rails.application.credentials.dig(:notion, :client_secret) || ENV["NOTION_CLIENT_SECRET"]

    response = HTTParty.post("https://api.notion.com/v1/oauth/token",
      headers: {
        "Authorization" => "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}",
        "Content-Type" => "application/json"
      },
      body: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: notion_callback_url
      }.to_json
    )

    unless response.success?
      raise "Token exchange failed: #{response.code} #{response.body}"
    end

    response.parsed_response
  end

  def fetch_user_info(access_token)
    response = HTTParty.get("https://api.notion.com/v1/users/me",
      headers: {
        "Authorization" => "Bearer #{access_token}",
        "Notion-Version" => "2022-06-28"
      }
    )

    unless response.success?
      raise "User info fetch failed: #{response.code} #{response.body}"
    end

    response.parsed_response
  end

  def notion_callback_url
    Rails.application.routes.url_helpers.notion_auth_callback_url(host: request.host_with_port, protocol: request.protocol)
  end
end

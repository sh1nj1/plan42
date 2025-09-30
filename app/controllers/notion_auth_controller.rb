class NotionAuthController < ApplicationController
  def callback
    unless Current.user
      render plain: "Unauthorized", status: :unauthorized
      return
    end

    auth = request.env["omniauth.auth"]
    unless auth
      render plain: "Missing auth data", status: :unprocessable_entity
      return
    end

    account = Current.user.notion_account || Current.user.build_notion_account
    account.notion_uid = auth.uid
    account.workspace_name = auth.info.workspace_name
    account.workspace_id = auth.info.workspace_id
    account.bot_id = auth.info.bot_id
    account.token = auth.credentials.token
    account.token_expires_at = Time.at(auth.credentials.expires_at) if auth.credentials.expires_at
    account.save!

    render layout: false
  rescue StandardError => e
    Rails.logger.error("Notion auth callback failed: #{e.class} #{e.message}")
    render plain: "Authentication failed", status: :internal_server_error
  end
end

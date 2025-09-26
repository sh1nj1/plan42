class GithubAuthController < ApplicationController
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

    account = Current.user.github_account || Current.user.build_github_account
    account.github_uid = auth.uid
    account.login = auth.info.nickname.presence || auth.extra.raw_info.login
    account.name = auth.info.name
    account.avatar_url = auth.info.image
    account.token = auth.credentials.token
    account.token_expires_at = Time.at(auth.credentials.expires_at) if auth.credentials.expires_at
    account.save!

    render layout: false
  rescue StandardError => e
    Rails.logger.error("Github auth callback failed: #{e.class} #{e.message}")
    render plain: "Authentication failed", status: :internal_server_error
  end
end

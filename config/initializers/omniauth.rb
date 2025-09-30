require Rails.root.join("lib", "omniauth", "strategies", "notion")

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           Rails.application.credentials.dig(:google, :client_id),
           Rails.application.credentials.dig(:google, :client_secret),
           scope: %w[
             https://www.googleapis.com/auth/userinfo.email
             https://www.googleapis.com/auth/calendar.app.created
           ].join(" "),
           access_type: "offline",
           prompt: "consent",
           include_granted_scopes: "true"

  github_client_id = Rails.application.credentials.dig(:github, :client_id) || ENV["GITHUB_CLIENT_ID"]
  github_client_secret = Rails.application.credentials.dig(:github, :client_secret) || ENV["GITHUB_CLIENT_SECRET"]
  if github_client_id.present? && github_client_secret.present?
    provider :github,
             github_client_id,
             github_client_secret,
             scope: "repo read:org admin:repo_hook",
             allow_signup: false
  end

  notion_client_id = Rails.application.credentials.dig(:notion, :client_id) || ENV["NOTION_CLIENT_ID"]
  notion_client_secret = Rails.application.credentials.dig(:notion, :client_secret) || ENV["NOTION_CLIENT_SECRET"]
  if notion_client_id.present? && notion_client_secret.present?
    provider :notion,
             notion_client_id,
             notion_client_secret,
             scope: "read write"
  end
end

OmniAuth.config.allowed_request_methods = %i[post]

require_relative "../../lib/omniauth/strategies/notion"

Rails.application.config.middleware.use OmniAuth::Builder do
  google_client_id = ENV["GOOGLE_CLIENT_ID"] || Rails.application.credentials.dig(:google, :client_id)
  google_client_secret = ENV["GOOGLE_CLIENT_SECRET"] || Rails.application.credentials.dig(:google, :client_secret)

  if google_client_id.present? && google_client_secret.present?
    provider :google_oauth2,
             google_client_id,
             google_client_secret,
             scope: %w[
               https://www.googleapis.com/auth/userinfo.email
               https://www.googleapis.com/auth/calendar.app.created
             ].join(" "),
             access_type: "offline",
             prompt: "consent",
             include_granted_scopes: "true"
  end

  github_client_id = ENV["GITHUB_CLIENT_ID"] || Rails.application.credentials.dig(:github, :client_id)
  github_client_secret = ENV["GITHUB_CLIENT_SECRET"] || Rails.application.credentials.dig(:github, :client_secret)
  if github_client_id.present? && github_client_secret.present?
    provider :github,
             github_client_id,
             github_client_secret,
             scope: "repo read:org admin:repo_hook",
             allow_signup: false
  end

  notion_client_id = ENV["NOTION_CLIENT_ID"] || Rails.application.credentials.dig(:notion, :client_id)
  notion_client_secret = ENV["NOTION_CLIENT_SECRET"] || Rails.application.credentials.dig(:notion, :client_secret)
  if notion_client_id.present? && notion_client_secret.present?
    provider :notion,
             notion_client_id,
             notion_client_secret
  end
end

OmniAuth.config.allowed_request_methods = %i[get post]

# Enable OmniAuth mock mode for development when GITHUB_MOCK=1
# This allows testing the GitHub integration UI without real credentials.
if ENV["GITHUB_MOCK"] == "1"
  OmniAuth.config.test_mode = true
  OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
    provider: "github",
    uid: "12345",
    info: {
      nickname: "dev-user",
      name: "Dev User",
      image: "https://avatars.githubusercontent.com/u/12345"
    },
    credentials: {
      token: "fake-dev-token"
    }
  )
end

require_relative "../../lib/omniauth/strategies/notion"

google_client_id = ENV["GOOGLE_CLIENT_ID"] || Rails.application.credentials.dig(:google, :client_id)
google_client_secret = ENV["GOOGLE_CLIENT_SECRET"] || Rails.application.credentials.dig(:google, :client_secret)
github_client_id = ENV["GITHUB_CLIENT_ID"] || Rails.application.credentials.dig(:github, :client_id)
github_client_secret = ENV["GITHUB_CLIENT_SECRET"] || Rails.application.credentials.dig(:github, :client_secret)
notion_client_id = ENV["NOTION_CLIENT_ID"] || Rails.application.credentials.dig(:notion, :client_id)
notion_client_secret = ENV["NOTION_CLIENT_SECRET"] || Rails.application.credentials.dig(:notion, :client_secret)

Rails.application.config.middleware.use OmniAuth::Builder do
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

  if github_client_id.present? && github_client_secret.present?
    provider :github,
             github_client_id,
             github_client_secret,
             scope: "repo read:org admin:repo_hook",
             allow_signup: false
  end

  if notion_client_id.present? && notion_client_secret.present?
    provider :notion,
             notion_client_id,
             notion_client_secret
  end
end

OmniAuth.config.allowed_request_methods = %i[get post]

# Enable OmniAuth mock mode in development when no real GitHub credentials are configured.
# The mock server (bin/rails collavre_github:mock_server) runs by default via Procfile.dev.
# Set GITHUB_MOCK=0 to explicitly disable mock mode even without credentials.
github_mock_enabled = if ENV.key?("GITHUB_MOCK")
                        ENV["GITHUB_MOCK"] == "1"
else
                        Rails.env.development? && github_client_id.blank?
end

if github_mock_enabled
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

Rails.application.config.middleware.use OmniAuth::Builder do
  google_client_id = Rails.application.credentials.dig(:google, :client_id) || ENV["GOOGLE_CLIENT_ID"]
  google_client_secret = Rails.application.credentials.dig(:google, :client_secret) || ENV["GOOGLE_CLIENT_SECRET"]

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

  github_client_id = Rails.application.credentials.dig(:github, :client_id) || ENV["GITHUB_CLIENT_ID"]
  github_client_secret = Rails.application.credentials.dig(:github, :client_secret) || ENV["GITHUB_CLIENT_SECRET"]
  if github_client_id.present? && github_client_secret.present?
    provider :github,
             github_client_id,
             github_client_secret,
             scope: "repo read:org admin:repo_hook",
             allow_signup: false
  end
end

OmniAuth.config.allowed_request_methods = %i[get post]

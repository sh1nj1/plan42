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
end

OmniAuth.config.allowed_request_methods = %i[post]

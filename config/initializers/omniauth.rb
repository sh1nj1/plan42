require_relative "../../lib/omniauth/strategies/notion"
require_relative "../../lib/omniauth/strategies/notion_mock"

# Register OAuth keys with the IntegrationSettings registry so the admin UI
# can surface them and `Collavre::IntegrationSettings::Resolver` can serve
# values via the DB > ENV > default precedence. Registered eagerly (not in
# `to_prepare`) because the middleware below resolves values at boot.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:google_client_id,     category: "google_oauth", sensitive: false, requires_restart: true)
  registry.register(:google_client_secret, category: "google_oauth", sensitive: true,  requires_restart: true)
  registry.register(:github_client_id,     category: "github_oauth", sensitive: false, requires_restart: true)
  registry.register(:github_client_secret, category: "github_oauth", sensitive: true,  requires_restart: true)
  registry.register(:notion_client_id,     category: "notion_oauth", sensitive: false, requires_restart: true)
  registry.register(:notion_client_secret, category: "notion_oauth", sensitive: true,  requires_restart: true)
  # Read at boot below, so it must be registered eagerly like `github_mock`
  # (see engines/collavre_github/config/initializers/integration_settings.rb).
  registry.register(:notion_mock,          category: "notion_oauth", sensitive: false, requires_restart: true)
end

resolve_oauth = lambda do |key, credentials_path|
  resolver_value =
    if defined?(Collavre::IntegrationSettings::Resolver)
      begin
        Collavre::IntegrationSettings::Resolver.get(key)
      rescue ActiveRecord::StatementInvalid,
             ActiveRecord::NoDatabaseError,
             ActiveRecord::ConnectionNotEstablished,
             NameError
        # DB not ready or model not yet autoloaded — fall back to ENV. The
        # registered `requires_restart` flag is still honoured: after the next
        # boot, the model is loaded and Resolver picks up DB values.
        ENV[key.to_s.upcase]
      end
    else
      ENV[key.to_s.upcase]
    end

  resolver_value.presence || Rails.application.credentials.dig(*credentials_path)
end

google_client_id     = resolve_oauth.call(:google_client_id,     %i[google client_id])
google_client_secret = resolve_oauth.call(:google_client_secret, %i[google client_secret])
github_client_id     = resolve_oauth.call(:github_client_id,     %i[github client_id])
github_client_secret = resolve_oauth.call(:github_client_secret, %i[github client_secret])
# Notion resolves through CollavreNotion rather than the lambda above: the same
# answer is needed at runtime by NotionClient and NotionAuthController, and when
# the three read it separately they drift (see CollavreNotion for the drift this
# closes). Same DB > ENV > credentials precedence.
notion_client_id     = CollavreNotion.client_id
notion_client_secret = CollavreNotion.client_secret

github_mock_setting = resolve_oauth.call(:github_mock, %i[github mock])
github_mock_enabled = if github_mock_setting.present?
                        github_mock_setting == "1"
else
                        Rails.env.development? && github_client_id.blank?
end

notion_mock_enabled = CollavreNotion.mock_enabled?

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
  elsif github_mock_enabled
    provider :github,
             "mock-client-id",
             "mock-client-secret",
             scope: "repo read:org admin:repo_hook",
             allow_signup: false
  end

  # Mock first, unlike GitHub above: NOTION_MOCK=1 is an operator saying "use the
  # mock", and it is only reachable with credentials present — the auto-enable
  # branch requires a blank client id, so the two orders agree everywhere else.
  if notion_mock_enabled
    provider OmniAuth::Strategies::NotionMock
  elsif notion_client_id.present? && notion_client_secret.present?
    provider :notion,
             notion_client_id,
             notion_client_secret
  end
end

OmniAuth.config.allowed_request_methods = %i[get post]

# Enable OmniAuth mock mode in development when no real credentials are configured.
# Mock servers run by default via Procfile.dev.
# Set GITHUB_MOCK=0 or NOTION_MOCK=0 to explicitly disable.
#
# Notion is deliberately not in this condition. test_mode is global — every
# provider goes through mock_auth once it is on — so mocking Notion used to
# disable real GitHub and Google logins for a developer who had credentials for
# them. Strategies::NotionMock replaces the flag for Notion: it is a strategy, so
# it only answers for /auth/notion.
if github_mock_enabled
  OmniAuth.config.test_mode = true
end

if github_mock_enabled
  OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
    provider: "github",
    uid: "12345",
    info: { nickname: "dev-user", name: "Dev User", image: "https://avatars.githubusercontent.com/u/12345" },
    credentials: { token: "fake-dev-token" }
  )
end

# Still seeded, even though NotionMock no longer needs it: GitHub's mock can have
# switched test_mode on globally, and OmniAuth's mock path bypasses the strategy
# and reads mock_auth[:notion] — falling back to mock_auth[:default], i.e. the
# wrong provider's identity, if it is missing. Keep it identical to the strategy's
# own hash so both routes produce the same account.
if notion_mock_enabled
  OmniAuth.config.mock_auth[:notion] = OmniAuth::AuthHash.new(
    provider: "notion",
    uid: "notion-dev-user-001",
    info: { name: "Dev Workspace", workspace_name: "Dev Workspace" },
    credentials: { token: "fake-notion-dev-token" }
  )
end

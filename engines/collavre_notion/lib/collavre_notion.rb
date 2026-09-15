require "collavre_notion/version"
require "collavre_notion/engine"
require "collavre_notion/mock_endpoint"

module CollavreNotion
  # Where the Notion integration points — real API or local mock — and the
  # credentials that decide it.
  #
  # Three callers have to agree on that answer: the OmniAuth middleware (once,
  # at boot), NotionClient (on every API call) and NotionAuthController (on
  # every callback). They did not. The middleware resolved the client id through
  # the DB-backed settings registry, then Rails credentials, and honoured an
  # explicit NOTION_MOCK; NotionClient looked only at ENV["NOTION_CLIENT_ID"].
  # A developer holding real credentials anywhere but ENV was therefore signed
  # in against Notion while their API calls went to localhost:4568, with
  # NOTION_MOCK=0 unable to stop it.
  class << self
    # The answer #mock_enabled? gave the first caller, held for the life of the
    # process. nil until then. Assign nil to re-resolve (tests only).
    attr_accessor :mock_latch
  end

  module_function

  def client_id
    setting(:notion_client_id, %i[notion client_id])
  end

  def client_secret
    setting(:notion_client_secret, %i[notion client_secret])
  end

  # Resolved once per process, then latched.
  #
  # The middleware can only ask at boot — OmniAuth::Builder registers a provider
  # or it does not — so the answer it got is the one the whole process has to
  # keep. Re-reading here would let an admin-UI edit move NotionClient's host
  # while the strategy that minted the tokens stayed where it was: an account
  # holding a real workspace token, sent to localhost. That is the same defect
  # as the one this method was written to close, only with time as the second
  # input instead of ENV. Both of these keys are registered
  # `requires_restart: true`, which is precisely this promise.
  #
  # The first caller is config/initializers/omniauth.rb, so the latched value is
  # the middleware's own decision by construction rather than by agreement.
  def mock_enabled?
    latched = CollavreNotion.mock_latch
    return latched unless latched.nil?

    CollavreNotion.mock_latch = resolve_mock_enabled
  end

  # An explicit setting wins in either direction. Otherwise the mock only stands
  # in where there is nothing to stand in for: development with no credentials.
  #
  # Never in production, whatever the setting says. The mock signs every browser
  # in as one fixed workspace with a fixed token, so an env var must not be able
  # to put a deployed host into it — which is also why NOTION_MOCK is
  # deliberately absent from .kamal/secrets and config/deploy.yml.
  def resolve_mock_enabled
    return false if Rails.env.production?

    explicit = setting(:notion_mock, %i[notion mock])
    return explicit.to_s == "1" if explicit.present?

    Rails.env.development? && client_id.blank?
  end

  # DB > ENV > credentials, the same precedence config/initializers/omniauth.rb
  # applies to the other providers.
  def setting(key, credentials_path)
    value =
      if defined?(Collavre::IntegrationSettings::Resolver)
        begin
          Collavre::IntegrationSettings::Resolver.get(key)
        rescue ActiveRecord::StatementInvalid,
               ActiveRecord::NoDatabaseError,
               ActiveRecord::ConnectionNotEstablished,
               NameError,
               Collavre::IntegrationSettings::Resolver::UnknownKeyError
          # Boot-time callers run before the database is reachable, and the keys
          # are registered by an initializer that a bare engine load will not have
          # run. These are all registered `requires_restart: true`, so the next
          # boot picks up a DB value; until then ENV is the answer.
          ENV[key.to_s.upcase]
        end
      else
        ENV[key.to_s.upcase]
      end

    value.presence || Rails.application.credentials.dig(*credentials_path)
  end
end

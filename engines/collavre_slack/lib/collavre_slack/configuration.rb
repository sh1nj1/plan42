module CollavreSlack
  # Slack engine configuration.
  #
  # OAuth credential getters (`client_id`, `client_secret`, `signing_secret`,
  # `redirect_uri`) resolve through `Collavre::IntegrationSettings::Resolver`,
  # which honors the DB > ENV > registered default precedence. Writers are
  # preserved so tests and explicit `CollavreSlack.configure` overrides keep
  # working: an explicitly-assigned value short-circuits the resolver.
  #
  # Fallback to plain `ENV[...]` when the resolver is not usable:
  #   - `integration_settings` table missing (db:create, db:schema:load,
  #     assets:precompile, fresh installs)
  #   - DB connection not established
  #   - `Collavre::IntegrationSettings` API not present in the installed
  #     core `collavre` gem (e.g. `USE_COLLAVRE_GEM=true` pinned to a
  #     version predating this feature)
  class Configuration
    RESOLVER_KEYS = {
      client_id:      { registry: :slack_client_id,      env: "SLACK_CLIENT_ID" },
      client_secret:  { registry: :slack_client_secret,  env: "SLACK_CLIENT_SECRET" },
      signing_secret: { registry: :slack_signing_secret, env: "SLACK_SIGNING_SECRET" },
      redirect_uri:   { registry: :slack_redirect_uri,   env: "SLACK_REDIRECT_URI" }
    }.freeze

    attr_writer :client_id, :client_secret, :signing_secret, :redirect_uri
    attr_accessor :scopes

    def initialize
      @scopes = ENV.fetch("SLACK_SCOPES", "chat:write,channels:read,channels:history,groups:read,im:read,mpim:read,users:read,users:read.email,reactions:read,reactions:write")
    end

    RESOLVER_KEYS.each do |attr, meta|
      define_method(attr) do
        ivar = instance_variable_get(:"@#{attr}")
        return ivar unless ivar.nil?

        resolve_setting(meta[:registry], meta[:env])
      end
    end

    private

    def resolve_setting(registry_key, env_var)
      return ENV[env_var] unless defined?(Collavre::IntegrationSettings::Resolver)

      Collavre::IntegrationSettings::Resolver.get(registry_key)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      ENV[env_var]
    end
  end
end

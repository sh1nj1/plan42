require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Use SECRET_KEY_BASE from environment variable (only if set, to allow
  # SECRET_KEY_BASE_DUMMY=1 during asset precompilation in Docker builds)
  config.secret_key_base = ENV["SECRET_KEY_BASE"] if ENV["SECRET_KEY_BASE"].present?

  # Enable HTTP compression for responses (gzip/deflate)
  # Reduces bandwidth by 60-70% for text-based responses
  config.middleware.use Rack::Deflater

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Pre-warm encryption fallback keys so `AwsCredentials.s3` (and any other
  # boot-time `IntegrationSettings.fetch(..., boot_safe: true)` call below)
  # can decrypt admin-saved DB rows even though
  # `config/initializers/active_record_encryption.rb` runs later. Without
  # this, the `boot_safe:` rescue would swallow the encryption error, return
  # blank credentials, and downgrade S3 storage to `:local` for the whole
  # boot — ignoring legitimate admin-saved DB credentials.
  EncryptionBootstrap.ensure_keys!(Rails.application)

  # Collavre uploaded files storage: S3 only when a source-coherent pair of
  # S3 credentials is available (`AwsCredentials.s3` enforces same-source
  # access key id + secret). When `Collavre::AwsCredentials` is unavailable
  # (`USE_COLLAVRE_GEM=true` with an older gem), fall back to plain ENV so
  # legacy env-based S3 deploys keep S3 selected. `CollavreCompat.call`
  # (loaded by `config/application.rb`) drops kwargs older gem versions
  # don't accept, avoiding ArgumentError under `USE_COLLAVRE_GEM=true`.
  s3_credentials =
    if defined?(Collavre::AwsCredentials)
      CollavreCompat.call(Collavre::AwsCredentials, :s3, boot_safe: true)
    elsif ENV["AWS_S3_ACCESS_KEY_ID"].present? && ENV["AWS_S3_SECRET_ACCESS_KEY"].present?
      { access_key_id: ENV["AWS_S3_ACCESS_KEY_ID"], secret_access_key: ENV["AWS_S3_SECRET_ACCESS_KEY"] }
    else
      {}
    end
  config.active_storage.service =
    if s3_credentials[:access_key_id].present? && s3_credentials[:secret_access_key].present?
      :amazon
    else
      :local
    end

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  # config.action_mailer.default_url_options = {
  #   host: ENV.fetch("DEFAULT_URL_HOST", "collavre.com")
  # }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # AWS SES SMTP. `AwsCredentials.ses_smtp` returns a source-coherent pair so
  # the baseline never mixes ENV with credentials. When `Collavre::AwsCredentials`
  # is unavailable (`USE_COLLAVRE_GEM=true` with an older gem), fall back to
  # plain ENV / Rails.credentials so legacy env-based deploys keep sending
  # mail. When the interceptor IS loaded, it overrides address/user_name/
  # password with DB > ENV > credentials at each send so admins can rotate
  # SES creds via /admin/integrations without redeploying.
  # Resolve ses_region from DB > ENV > Rails.credentials so an admin-only SES
  # setup (region + creds all stored in `integration_settings`) still emits an
  # SES-shaped baseline address at boot. Without DB lookup here the scaffold
  # leaves `:address` nil → compact removes it → `Mail::SMTP` falls back to
  # `"localhost"`, which the interceptor's `ses_target?` now rejects, leaving
  # production trying to authenticate to localhost with DB SES creds.
  ses_region =
    if defined?(Collavre::IntegrationSettings)
      CollavreCompat.call(
        Collavre::IntegrationSettings,
        :fetch,
        :aws_region,
        default: ENV["AWS_REGION"],
        boot_safe: true
      ).presence || Rails.application.credentials.dig(:aws, :region)
    else
      ENV["AWS_REGION"].presence || Rails.application.credentials.dig(:aws, :region)
    end
  ses_smtp_credentials =
    if defined?(Collavre::AwsCredentials)
      CollavreCompat.call(Collavre::AwsCredentials, :ses_smtp, boot_safe: true)
    else
      legacy_user = ENV["AWS_SES_SMTP_USERNAME"].presence || Rails.application.credentials.dig(:aws, :smtp_username).presence
      legacy_pass = ENV["AWS_SES_SMTP_PASSWORD"].presence || Rails.application.credentials.dig(:aws, :smtp_password).presence
      legacy_user && legacy_pass ? { user_name: legacy_user, password: legacy_pass } : {}
    end

  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address:              ("email-smtp.#{ses_region}.amazonaws.com" if ses_region.present?),
    port:                 587,
    user_name:            ses_smtp_credentials[:user_name],
    password:             ses_smtp_credentials[:password],
    authentication:       :plain,
    enable_starttls_auto: true
  }.compact

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end

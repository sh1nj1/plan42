# Desktop app environment.
#
# Inherits the full production configuration (Solid stack, eager load, asset
# serving, caching) and overrides only what a locally-bundled, loopback-served
# desktop app needs. Loading production.rb first means this env tracks any
# production change automatically instead of drifting from a hand-maintained
# copy.
require_relative "production"

Rails.application.configure do
  # The Tauri shell loads the app over plain HTTP on a loopback port. Production
  # hardcodes assume_ssl/force_ssl = true, which would 301-redirect the webview
  # to https:// and break it (and set Secure-only cookies the http origin can't
  # send back). Loopback traffic never leaves the machine, so disable both.
  config.assume_ssl = false
  config.force_ssl = false

  # Keep all uploaded files on local disk. Even if stray S3 credentials are
  # present in the environment, a desktop install must never reach for S3.
  config.active_storage.service = :local

  # Keep DNS-rebinding protection ON. The webview talks to the sidecar over
  # loopback, so only loopback Host headers are allowed by default. A malicious
  # page that rebinds its own domain to 127.0.0.1 still sends *its* hostname as
  # the Host header, which is rejected here. Open mode (0.0.0.0 / Tailscale) is
  # reached via a non-loopback hostname, so the launcher passes the externally
  # reachable host(s) through COLLAVRE_ALLOWED_HOSTS to widen the allowlist.
  require "ipaddr"
  config.hosts = [ "localhost", IPAddr.new("127.0.0.0/8"), IPAddr.new("::1") ]
  if (extra = ENV["COLLAVRE_ALLOWED_HOSTS"]).present?
    config.hosts.concat(extra.split(",").map(&:strip).reject(&:empty?))
  end

  # A local desktop install has no SMTP/SES, so the email verification link can
  # never be delivered. Without this the first locally-created user enqueues a
  # verification mail that never arrives, and login rejects them as unverified —
  # a hard lockout. Auto-verify signups here; the machine's owner is the only
  # user, so there is no email-ownership to prove.
  config.x.auto_verify_email = true

  # Production sets delivery_method = :smtp with SES credentials that are absent
  # on a desktop install, so inheriting it makes every *other* user-triggered
  # mail (password reset, share invites) enqueue a Solid Queue job that can never
  # connect and is retried forever, while the UI claims the mail was sent.
  # Deliver to a file under the writable data dir instead: deliveries succeed (no
  # doomed SMTP retries), and the single local owner can open the message to
  # retrieve a link — e.g. a password-reset URL — the loopback app can't email.
  # Covers all mail actions, not just the auto-verified signup above.
  config.action_mailer.delivery_method = :file
  config.action_mailer.raise_delivery_errors = false
  if (mail_data_dir = ENV["COLLAVRE_DATA_DIR"]).present?
    require "fileutils"
    mail_dir = File.join(mail_data_dir, "mail")
    FileUtils.mkdir_p(mail_dir)
    config.action_mailer.file_settings = { location: mail_dir }
  end

  # Ship no known admin credential. The generic seed creates admin@example.com
  # with a public default password, which would be a standing backdoor on every
  # desktop install (worse in open mode). Instead the owner is bootstrapped via
  # first-run signup: the seed skips the default admin, and the first registered
  # user is granted system_admin (the default build is loopback-only, so that
  # first signup is the local owner; open mode is opt-in and set up afterwards).
  config.x.bootstrap_first_admin = true

  # Boot must not depend on a checked-in master key. The desktop launcher
  # provisions and persists SECRET_KEY_BASE on first run (see
  # tools/desktop-app/scripts/provision-secrets.rb) and exports it before boot.
  config.secret_key_base = ENV["SECRET_KEY_BASE"] if ENV["SECRET_KEY_BASE"].present?

  # Log to a file under the data dir by default so a packaged .app (no attached
  # terminal) still leaves a debuggable trail. Falls back to STDOUT when no data
  # dir is set (e.g. running the desktop env from a dev checkout).
  if (data_dir = ENV["COLLAVRE_DATA_DIR"]).present?
    log_path = File.join(data_dir, "log", "desktop.log")
    require "fileutils"
    FileUtils.mkdir_p(File.dirname(log_path))
    config.logger = ActiveSupport::TaggedLogging.new(Logger.new(log_path))
    config.log_tags = [ :request_id ]
  end
end

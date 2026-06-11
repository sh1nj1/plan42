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

  # Single-user desktop install: allow the loopback hosts the Tauri shell may
  # bind to (127.0.0.1 / localhost / 0.0.0.0 in "open" mode). Empty host
  # authorization (production default) already permits these; this is explicit
  # so DNS-rebinding protection can be tightened later without surprise.
  config.hosts.clear
  config.host_authorization = { exclude: ->(_request) { true } }

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

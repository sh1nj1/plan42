WebAuthn.configure do |config|
  if Rails.env.test?
    config.allowed_origins = [ "http://www.example.com" ]
  else
    url_options = Rails.configuration.action_controller.default_url_options
    origin = "#{url_options[:protocol]}://#{url_options[:host]}"
    origin << ":#{url_options[:port]}" if url_options[:port]
    config.allowed_origins = [ origin ]
  end
  config.rp_name = I18n.t("app.name")
  config.credential_options_timeout = 120000
end

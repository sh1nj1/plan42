# Register FCM keys with the IntegrationSettings registry so the admin UI can
# surface them and `Collavre::IntegrationSettings::Resolver` can serve values
# via the DB > ENV > credentials precedence. Registered eagerly because the
# FCM client is wired into `Rails.application.config.x.*` at boot.
#
# Firebase keys are also registered here defensively: this initializer (`fcm.rb`)
# loads before `firebase_config.rb` alphabetically, so without these guards
# `IntegrationSettings.fetch(:firebase_*)` would raise `UnknownKeyError` and the
# helper would swallow it to nil — losing the ENV fallback. `register` is
# idempotent (last write wins), so `firebase_config.rb` re-registering is safe.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:fcm_server_key,                  category: "fcm", sensitive: true,  requires_restart: true)
  registry.register(:fcm_sender_id,                   category: "fcm", sensitive: false, requires_restart: true)
  registry.register(:fcm_vapid_key,                   category: "fcm", sensitive: true,  requires_restart: true)
  # Hidden from admin UI: ADC file path is a developer-local convenience read
  # from ENV/credentials only. Production should use firebase_service_account_json
  # (DB textarea) or WIF instead.
  registry.register(:google_application_credentials,  category: "fcm", sensitive: true,  requires_restart: true,
                                                      admin_visible: false)
  registry.register(:firebase_service_account_json,   category: "fcm", sensitive: true,  requires_restart: true,
                                                      input_type: :textarea)
  registry.register(:fcm_wif_audience,                category: "fcm", sensitive: false, requires_restart: true)
  registry.register(:fcm_wif_credential_source,       category: "fcm", sensitive: true,  requires_restart: true,
                                                      input_type: :textarea)
  registry.register(:fcm_wif_service_account_email,   category: "fcm", sensitive: false, requires_restart: true)
  registry.register(:firebase_project_id,             category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_service_account,        category: "firebase", sensitive: true,  requires_restart: true)
end

resolve = ->(key, credentials_path) {
  value = CollavreCompat.call(Collavre::IntegrationSettings, :fetch, key, boot_safe: true)
  value.presence || Rails.application.credentials.dig(*credentials_path)
}

FCM_SCOPE = [ Google::Apis::FcmV1::AUTH_FIREBASE_MESSAGING ].freeze

server_key                  = resolve.call(:fcm_server_key,                 %i[fcm server_key])
project_id                  = resolve.call(:firebase_project_id,            %i[firebase project_id])
service_account_email       = resolve.call(:firebase_service_account,       %i[fcm service_account])
service_account_json_body   = resolve.call(:firebase_service_account_json,  %i[fcm service_account_json])
wif_audience                = resolve.call(:fcm_wif_audience,               %i[fcm wif_audience])
wif_credential_source       = resolve.call(:fcm_wif_credential_source,      %i[fcm wif_credential_source])
wif_sa_email                = resolve.call(:fcm_wif_service_account_email,  %i[fcm wif_service_account_email]).presence || service_account_email
adc_path                    = resolve.call(:google_application_credentials, %i[fcm google_application_credentials])

build_service_account_credentials = ->(json_body) {
  Google::Auth::ServiceAccountCredentials.make_creds(
    json_key_io: StringIO.new(json_body),
    scope: FCM_SCOPE
  )
}

build_adc_credentials = ->(path) {
  # `Google::Auth.get_application_default` reads `ENV["GOOGLE_APPLICATION_CREDENTIALS"]`,
  # so we must export the resolved path before the ADC lookup. Overwrite
  # unconditionally — `resolve` already applied DB > ENV precedence, so any
  # pre-existing ENV value lost that race and must not leak back into ADC.
  ENV["GOOGLE_APPLICATION_CREDENTIALS"] = path
  Google::Auth.get_application_default(scope: FCM_SCOPE)
}

build_wif_credentials = ->(audience, credential_source_json, sa_email) {
  source = JSON.parse(credential_source_json)
  impersonation_url = sa_email.present? ?
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/#{sa_email}:generateAccessToken" :
    nil

  Google::Auth::ExternalAccount::AwsCredentials.new(
    universe_domain: "googleapis.com",
    type: "external_account",
    audience: audience,
    subject_token_type: "urn:ietf:params:aws:token-type:aws4_request",
    token_url: "https://sts.googleapis.com/v1/token",
    scope: FCM_SCOPE,
    credential_source: source,
    service_account_impersonation_url: impersonation_url
  )
}

credentials = nil
mode = nil

if service_account_json_body.present?
  begin
    credentials = build_service_account_credentials.call(service_account_json_body)
    mode = "service account JSON (DB/ENV)"
  rescue StandardError => e
    Rails.logger.error "FCM: failed to parse firebase_service_account_json: #{e.class}: #{e.message}"
  end
elsif wif_audience.present? && wif_credential_source.present?
  begin
    credentials = build_wif_credentials.call(wif_audience, wif_credential_source, wif_sa_email)
    mode = "Workload Identity Federation (AWS)"
  rescue StandardError => e
    Rails.logger.error "FCM: failed to build WIF credentials: #{e.class}: #{e.message}"
  end
elsif adc_path.present? && File.exist?(adc_path)
  credentials = build_adc_credentials.call(adc_path)
  mode = "ADC file (#{adc_path})"
end

if credentials && project_id.present?
  service = Google::Apis::FcmV1::FirebaseCloudMessagingService.new
  service.authorization = credentials

  Rails.application.config.x.fcm_service = service
  Rails.application.config.x.fcm_project_id = project_id

  Rails.logger.info "FCM initialized with #{mode}"
  puts "FCM initialized with #{mode}"
elsif Rails.env.production?
  Rails.logger.warn "FCM not initialized: no valid credentials found"
end

if server_key.present?
  Rails.application.config.x.fcm_client = FCM.new(server_key)
end

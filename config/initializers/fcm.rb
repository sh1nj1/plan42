# Register Firebase/FCM keys with the IntegrationSettings registry so the admin
# UI can surface them and `Collavre::IntegrationSettings::Resolver` can serve
# values via the DB > ENV > credentials precedence. Registered eagerly because
# the FCM client is wired into `Rails.application.config.x.*` at boot.
#
# Firebase JS-config keys are also registered here defensively: this initializer
# (`fcm.rb`) loads before `firebase_config.rb` alphabetically, so without these
# guards `IntegrationSettings.fetch(:firebase_*)` would raise `UnknownKeyError`
# and the helper would swallow it to nil — losing the ENV fallback. `register`
# is idempotent (last write wins), so `firebase_config.rb` re-registering is safe.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:firebase_project_id,             category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_service_account_json,   category: "firebase", sensitive: true,  requires_restart: true,
                                                      input_type: :textarea)
  registry.register(:fcm_wif_audience,                category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:fcm_wif_credential_source,       category: "firebase", sensitive: true,  requires_restart: true,
                                                      input_type: :textarea)
  registry.register(:fcm_wif_service_account_email,   category: "firebase", sensitive: false, requires_restart: true,
                                                      env_var: "FIREBASE_SERVICE_ACCOUNT")
  registry.register(:fcm_sender_id,                   category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:fcm_vapid_key,                   category: "firebase", sensitive: true,  requires_restart: true)
  registry.register(:fcm_server_key,                  category: "firebase", sensitive: true,  requires_restart: true)
  # Hidden from admin UI: ADC file path is a developer-local convenience read
  # from ENV/credentials only. Production should use firebase_service_account_json
  # (DB textarea) or WIF instead.
  registry.register(:google_application_credentials,  category: "firebase", sensitive: true,  requires_restart: true,
                                                      admin_visible: false)
end

resolve = ->(key, credentials_path) {
  value = CollavreCompat.call(Collavre::IntegrationSettings, :fetch, key, boot_safe: true)
  value.presence || Rails.application.credentials.dig(*credentials_path)
}

fcm_scope = [ Google::Apis::FcmV1::AUTH_FIREBASE_MESSAGING ].freeze

# Default AWS Workload Identity Federation settings. Used as a fallback so the
# pre-existing production deploy — which only injects FCM_SENDER_ID (the GCP
# project number) and FIREBASE_SERVICE_ACCOUNT (the SA email) — keeps working
# without having to set the explicit fcm_wif_* overrides. Admins can override
# either piece via the admin UI / ENV for non-default pools or providers.
default_aws_audience = ->(project_number) {
  "//iam.googleapis.com/projects/#{project_number}/locations/global/workloadIdentityPools/aws-pool/providers/aws-provider"
}
default_aws_credential_source = {
  environment_id: "aws1",
  region_url: "http://169.254.169.254/latest/meta-data/placement/availability-zone",
  url: "http://169.254.169.254/latest/meta-data/iam/security-credentials",
  regional_cred_verification_url: "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15",
  imdsv2_session_token_url: "http://169.254.169.254/latest/api/token"
}.freeze

server_key                  = resolve.call(:fcm_server_key,                 %i[fcm server_key])
project_id                  = resolve.call(:firebase_project_id,            %i[firebase project_id])
project_number              = resolve.call(:fcm_sender_id,                  %i[fcm sender_id])
service_account_json_body   = resolve.call(:firebase_service_account_json,  %i[fcm service_account_json])
wif_audience_explicit       = resolve.call(:fcm_wif_audience,               %i[fcm wif_audience])
wif_credential_source_raw   = resolve.call(:fcm_wif_credential_source,      %i[fcm wif_credential_source])
# Single SA-email key. `fcm_wif_service_account_email` is registered with the
# legacy FIREBASE_SERVICE_ACCOUNT env var so existing prod deploys resolve here
# unchanged; the `firebase_service_account` key/credentials path stays readable
# as an extra fallback for older setups.
wif_sa_email                = resolve.call(:fcm_wif_service_account_email,  %i[fcm wif_service_account_email]).presence ||
                              Rails.application.credentials.dig(:firebase, :service_account)
adc_path                    = resolve.call(:google_application_credentials, %i[fcm google_application_credentials])

build_service_account_credentials = ->(json_body) {
  Google::Auth::ServiceAccountCredentials.make_creds(
    json_key_io: StringIO.new(json_body),
    scope: fcm_scope
  )
}

build_adc_credentials = ->(path) {
  # `Google::Auth.get_application_default` reads `ENV["GOOGLE_APPLICATION_CREDENTIALS"]`,
  # so we must export the resolved path before the ADC lookup. Overwrite
  # unconditionally — `resolve` already applied DB > ENV precedence, so any
  # pre-existing ENV value lost that race and must not leak back into ADC.
  ENV["GOOGLE_APPLICATION_CREDENTIALS"] = path
  Google::Auth.get_application_default(scope: fcm_scope)
}

build_wif_credentials = ->(audience, credential_source_raw, sa_email) {
  # AwsCredentials reads the source with symbol keys (`source[:environment_id]`),
  # so explicit JSON must be parsed with symbolize_names. Parsing happens here
  # (lazily, inside the rescued attempt) so a malformed override can't crash boot.
  credential_source = credential_source_raw.present? ?
    JSON.parse(credential_source_raw, symbolize_names: true) :
    default_aws_credential_source

  impersonation_url = sa_email.present? ?
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/#{sa_email}:generateAccessToken" :
    nil

  Google::Auth::ExternalAccount::AwsCredentials.new(
    universe_domain: "googleapis.com",
    type: "external_account",
    audience: audience,
    subject_token_type: "urn:ietf:params:aws:token-type:aws4_request",
    token_url: "https://sts.googleapis.com/v1/token",
    scope: fcm_scope,
    credential_source: credential_source,
    service_account_impersonation_url: impersonation_url
  )
}

# WIF is reachable two ways:
#   * explicit — admin/ENV sets both fcm_wif_audience and fcm_wif_credential_source
#     (works in any environment, for non-AWS-default pools/providers)
#   * legacy   — production with only FCM_SENDER_ID set; audience + credential
#     source fall back to the AWS defaults (preserves pre-existing prod behavior)
wif_audience = wif_audience_explicit.presence ||
               (project_number.present? ? default_aws_audience.call(project_number) : nil)
wif_explicit = wif_audience_explicit.present? && wif_credential_source_raw.present?
wif_legacy   = Rails.env.production? && project_number.present?
wif_enabled  = wif_audience.present? && (wif_explicit || wif_legacy)

# Ordered credential attempts. Each is tried only when its inputs are present,
# and a failure falls through to the next instead of dead-ending — so a malformed
# service-account JSON paste cannot silently disable a working WIF/ADC setup.
attempts = []
if service_account_json_body.present?
  attempts << [ "service account JSON (DB/ENV)", -> { build_service_account_credentials.call(service_account_json_body) } ]
end
if wif_enabled
  attempts << [ "Workload Identity Federation (AWS)", -> { build_wif_credentials.call(wif_audience, wif_credential_source_raw, wif_sa_email) } ]
end
if adc_path.present? && File.exist?(adc_path)
  attempts << [ "ADC file (#{adc_path})", -> { build_adc_credentials.call(adc_path) } ]
end

credentials = nil
mode = nil
attempts.each do |attempt_mode, builder|
  begin
    credentials = builder.call
    mode = attempt_mode
    break if credentials
  rescue StandardError => e
    # Log the error class only — never the message. JSON::ParserError#message
    # echoes the surrounding source, which for a service-account key includes
    # part of the private_key and would leak it into log sinks.
    Rails.logger.error "FCM: #{attempt_mode} credential init failed: #{e.class}"
  end
end

if credentials && project_id.present?
  service = Google::Apis::FcmV1::FirebaseCloudMessagingService.new
  service.authorization = credentials

  Rails.application.config.x.fcm_service = service
  Rails.application.config.x.fcm_project_id = project_id

  Rails.logger.info "FCM initialized with #{mode}"
  puts "FCM initialized with #{mode}"
elsif Rails.env.production?
  reason =
    if credentials && project_id.blank?
      # Credentials built fine; the operator just forgot the project id. Say so
      # explicitly so they don't go hunting for a bogus credentials problem.
      "credentials resolved via #{mode} but firebase_project_id is blank"
    elsif credentials.nil? && project_id.present?
      "no valid credentials found"
    else
      "no valid credentials found and firebase_project_id is blank"
    end
  Rails.logger.warn "FCM not initialized: #{reason}"
end

if server_key.present?
  Rails.application.config.x.fcm_client = FCM.new(server_key)
end

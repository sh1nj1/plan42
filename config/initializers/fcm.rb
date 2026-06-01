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
  registry.register(:google_application_credentials,  category: "fcm", sensitive: true,  requires_restart: true)
  registry.register(:firebase_project_id,             category: "firebase", sensitive: false, requires_restart: true)
  registry.register(:firebase_service_account,        category: "firebase", sensitive: true,  requires_restart: true)
end

resolve = ->(key, credentials_path) {
  value = Collavre::IntegrationSettings.fetch(key, boot_safe: true)
  value.presence || Rails.application.credentials.dig(*credentials_path)
}

server_key      = resolve.call(:fcm_server_key,                 %i[fcm server_key])
project_id      = resolve.call(:firebase_project_id,            %i[firebase project_id])
project_number  = resolve.call(:fcm_sender_id,                  %i[fcm sender_id])
service_account = resolve.call(:firebase_service_account,       %i[fcm service_account])

# Use service account JSON for local development
FCM_CREDENTIALS = resolve.call(:google_application_credentials, %i[fcm google_application_credentials])
if FCM_CREDENTIALS.present? && File.exist?(FCM_CREDENTIALS)

  # `Google::Auth.get_application_default` reads `ENV["GOOGLE_APPLICATION_CREDENTIALS"]`,
  # so we must export the resolved path before the ADC lookup. Overwrite
  # unconditionally — `resolve` already applied DB > ENV precedence, so any
  # pre-existing ENV value lost that race and must not leak back into ADC.
  ENV["GOOGLE_APPLICATION_CREDENTIALS"] = FCM_CREDENTIALS

  # Use default application credentials (reads from GOOGLE_APPLICATION_CREDENTIALS env var)
  credentials = Google::Auth.get_application_default(
    scope: [ Google::Apis::FcmV1::AUTH_FIREBASE_MESSAGING ]
  )

  service = Google::Apis::FcmV1::FirebaseCloudMessagingService.new
  service.authorization = credentials

  Rails.application.config.x.fcm_service = service
  Rails.application.config.x.fcm_project_id = project_id

  Rails.logger.info "FCM initialized with service account credentials from #{FCM_CREDENTIALS}"
  puts "FCM initialized with service account credentials from #{FCM_CREDENTIALS}"

elsif project_id.present? && Rails.env.production?
  Rails.logger.info "FCM initialized with service account credentials from #{service_account}"
  puts "FCM initialized with service account credentials from #{service_account}"
  # Use Workload Identity Federation for production (AWS EC2)
  audience = "//iam.googleapis.com/projects/#{project_number}/locations/global/workloadIdentityPools/aws-pool/providers/aws-provider"

  credentials = Google::Auth::ExternalAccount::AwsCredentials.new(
    universe_domain: "googleapis.com",
    type: "external_account",
    audience: audience,
    subject_token_type: "urn:ietf:params:aws:token-type:aws4_request",
    token_url: "https://sts.googleapis.com/v1/token",
    scope: [ Google::Apis::FcmV1::AUTH_FIREBASE_MESSAGING ],
    credential_source: {
      environment_id: "aws1",
      region_url: "http://169.254.169.254/latest/meta-data/placement/availability-zone",
      url: "http://169.254.169.254/latest/meta-data/iam/security-credentials",
      regional_cred_verification_url: "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15",
      imdsv2_session_token_url: "http://169.254.169.254/latest/api/token"
    },
    service_account_impersonation_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/#{service_account}:generateAccessToken"
  )

  service = Google::Apis::FcmV1::FirebaseCloudMessagingService.new
  service.authorization = credentials

  Rails.application.config.x.fcm_service = service
  Rails.application.config.x.fcm_project_id = project_id
end

if server_key.present?
  Rails.application.config.x.fcm_client = FCM.new(server_key)
end

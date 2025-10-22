server_key = ENV["FCM_SERVER_KEY"] || Rails.application.credentials.dig(:fcm, :server_key)
project_id = ENV["FIREBASE_PROJECT_ID"] || Rails.application.credentials.dig(:firebase, :project_id)
project_number = ENV["FCM_SENDER_ID"] || Rails.application.credentials.dig(:fcm, :sender_id)
service_account = "firebase-adminsdk-fbsvc@collavre.iam.gserviceaccount.com"

# Use service account JSON for local development
FCM_CREDENTIALS = ENV["GOOGLE_APPLICATION_CREDENTIALS"]
if FCM_CREDENTIALS.present? && File.exist?(FCM_CREDENTIALS)

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

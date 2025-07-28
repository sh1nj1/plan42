server_key = Rails.application.credentials.dig(:fcm, :server_key) || ENV["FCM_SERVER_KEY"]
project_id = Rails.application.credentials.dig(:firebase, :project_id)
project_number = Rails.application.credentials.dig(:fcm, :sender_id)
service_account = "firebase-adminsdk-fbsvc@collavre.iam.gserviceaccount.com"

if project_id.present?
  require "google/apis/fcm_v1"
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

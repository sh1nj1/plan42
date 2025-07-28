

ENV["AWS_REGION"] = nil

module Google
  module Auth
    module ExternalAccount
      module BaseCredentials
        def log_impersonated_token_request(original_token)
            digest = Digest::SHA256.hexdigest original_token
            msg = Google::Logging::Message.from(
              message: "Requesting impersonated access token with original token (sha256:#{digest})",
              "credentialsId" => object_id
            )
            Rails.logger.info("[IMPERSONATION] >>> token: #{msg}")
        end
        def get_impersonated_access_token(token, _options = {})
          log_impersonated_token_request token
          response = connection.post @service_account_impersonation_url do |req|
            req.headers["Authorization"] = "Bearer #{token}"
            req.headers["Content-Type"] = "application/json"
            req.body = MultiJson.dump({ scope: @scope })
          end

          Rails.logger.info("[IMPERSONATION] >>> URL: #{@service_account_impersonation_url}, scope: #{@scope}")
          Rails.logger.info("[IMPERSONATION] >>> token: #{token}")

          if response.status != 200
            Rails.logger.info("[IMPERSONATION] <<< RESPONSE BODY: #{response.body}")
            raise CredentialsError.with_details(
              "Service account impersonation failed with status #{response.status}",
              credential_type_name: self.class.name,
              principal: principal
            )
          end

          MultiJson.load response.body
        end
      end
    end
    module OAuth2
      class STSClient
        def exchange_token(options = {})
          missing_required_opts = [ :grant_type, :subject_token, :subject_token_type ] - options.keys
          unless missing_required_opts.empty?
            raise ArgumentError, "Missing required options: #{missing_required_opts.join(', ')}"
          end

          headers = URLENCODED_HEADERS.dup.merge(options[:additional_headers] || {})
          request_body = make_request(options)

          Rails.logger.info("[STS] >>> REQUEST HEADERS: #{headers.inspect}")
          Rails.logger.info("[STS] >>> REQUEST OPTIONs: #{options.inspect}")
          Rails.logger.info("[STS] >>> REQUEST BODY: #{request_body.inspect}")
          Rails.logger.info("[STS] >>> TOKEN URL: #{@token_exchange_endpoint}")

          response = connection.post(@token_exchange_endpoint, URI.encode_www_form(request_body), headers)

          Rails.logger.info("[STS] <<< RESPONSE STATUS: #{response.status}")
          Rails.logger.info("[STS] <<< RESPONSE BODY: #{response.body}")

          if response.status != 200
            raise "Token exchange failed with status #{response.status}. Body: #{response.body}"
          end

          MultiJson.load(response.body)
        end
      end
    end
  end
end


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

def send_v1(service, project_id, token, message, link)
  notification = Google::Apis::FcmV1::Notification.new(
    title: "새 알림",
    body: message
  )

  webpush = Google::Apis::FcmV1::WebpushConfig.new(
    fcm_options: Google::Apis::FcmV1::WebpushFcmOptions.new(link: link)
  )

  msg = Google::Apis::FcmV1::Message.new(
    token: token,
    notification: notification,
    webpush: webpush
  )

  request = Google::Apis::FcmV1::SendMessageRequest.new(message: msg)
  begin
    response = service.send_message("projects/#{project_id}", request)
    Rails.logger.info("✅ Push sent successfully: #{response.inspect}")
  rescue StandardError => e
    Rails.logger.info("❌ Push failed: #{e.inspect}", e)
  end
end

test_token = "eVgDudbc8UfcjwElNpDT_Y:APA91bEWxJdqbJFiXPAFQ8SjIF3NadvblT-VtGigL63ixeKqBtMTwB7Yt2UaQUwqNCLu6V0gsIfUqUMABw7OE3QZzv-rTnobsW0HmxmDo6owh1aBQxyNmuc"

send_v1(service, project_id, test_token, "test message", "https://google.com")

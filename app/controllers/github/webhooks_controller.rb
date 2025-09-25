module Github
  class WebhooksController < ActionController::API
    def create
      event = request.headers["X-GitHub-Event"]
      raw_body = request.raw_post.presence || request.body.read
      return head :unauthorized unless valid_signature?(raw_body)

      payload = request.request_parameters.presence
      payload ||= raw_body.present? ? JSON.parse(raw_body) : {}

      case event
      when "pull_request"
        Github::PullRequestProcessor.new(payload: payload).call
      else
        Rails.logger.debug("Unhandled GitHub event: #{event}")
      end

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def valid_signature?(raw_body)
      secret = webhook_secret
      signature_header = request.headers["X-Hub-Signature-256"] || request.headers["X-Hub-Signature"]

      if secret.blank?
        Rails.logger.warn("GitHub webhook secret missing; rejecting request")
        return false
      end

      return false if signature_header.blank?

      algorithm =
        if signature_header.start_with?("sha256=")
          "sha256"
        elsif signature_header.start_with?("sha1=")
          "sha1"
        end

      return false if algorithm.blank?

      digest = OpenSSL::HMAC.hexdigest(algorithm.upcase, secret, raw_body)
      expected_signature = "#{algorithm}=#{digest}"

      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature_header)
    end

    def webhook_secret
      Rails.application.credentials.dig(:github, :webhook_secret) || ENV["GITHUB_WEBHOOK_SECRET"]
    end
  end
end

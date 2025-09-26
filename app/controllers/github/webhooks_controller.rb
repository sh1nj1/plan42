module Github
  class WebhooksController < ActionController::API
    def create
      event = request.headers["X-GitHub-Event"]
      raw_body = request.raw_post.presence || request.body.read
      payload = parse_payload(raw_body)
      return head :unauthorized unless valid_signature?(raw_body, payload)
      payload = payload.presence || {}

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

    def valid_signature?(raw_body, payload)
      secret = webhook_secret(payload)
      signature_header = request.headers["X-Hub-Signature-256"] || request.headers["X-Hub-Signature"]

      if secret.blank?
        Rails.logger.warn("GitHub webhook secret missing; rejecting request")
        return false
      end

      return false if signature_header.blank?

      algorithm, provided_digest = signature_header.to_s.split("=", 2)
      algorithm = algorithm.to_s.downcase
      provided_digest = provided_digest.to_s.strip.downcase

      return false if provided_digest.blank?

      return false unless %w[sha256 sha1].include?(algorithm)

      expected_digest =
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new(algorithm), secret, raw_body)

      return false if expected_digest.bytesize != provided_digest.bytesize

      ActiveSupport::SecurityUtils.secure_compare(expected_digest, provided_digest)
    rescue ArgumentError
      false
    end

    def webhook_secret(payload)
      repository_secret(payload) || fallback_webhook_secret
    end

    def repository_secret(payload)
      return if payload.blank?

      repo = payload["repository"] || payload[:repository]
      return if repo.blank?

      full_name = repo["full_name"] || repo[:full_name]
      return if full_name.blank?

      GithubRepositoryLink.find_by(repository_full_name: full_name)&.webhook_secret
    end

    def fallback_webhook_secret
      Rails.application.credentials.dig(:github, :webhook_secret) || ENV["GITHUB_WEBHOOK_SECRET"]
    end

    def parse_payload(raw_body)
      request.request_parameters.presence ||
        (raw_body.present? ? JSON.parse(raw_body) : nil)
    end
  end
end

module Github
  class WebhooksController < ActionController::API
    def create
      event = github_event_header
      if event.blank?
        Rails.logger.warn("GitHub event header missing; rejecting request")
        return head :bad_request
      end
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

    def webhook_secret(payload)
      repository_secret(payload) || fallback_webhook_secret
    end

    def repository_secret(payload)
      return if payload.blank?

      repo = payload["repository"] || payload[:repository]
      if repo.blank?
        Rails.logger.warn("GitHub webhook repository missing; rejecting request. payload=#{payload}")
        return
      end

      full_name = repo["full_name"] || repo[:full_name]
      if full_name.blank?
        Rails.logger.warn("GitHub webhook repository full name missing; rejecting request. payload=#{payload}")
        return
      end

      GithubRepositoryLink.find_by(repository_full_name: full_name)&.webhook_secret
    end

    def fallback_webhook_secret
      ENV["GITHUB_WEBHOOK_SECRET"] || Rails.application.credentials.dig(:github, :webhook_secret)
    end

    def parse_payload(raw_body)
      params = request.request_parameters
      parsed_params =
        case params
        when ActionController::Parameters
          params.to_unsafe_h
        else
          params
        end

      if parsed_params.present?
        wrapper_payload = parsed_params.with_indifferent_access[:payload]
        return wrapper_payload if wrapper_payload.is_a?(Hash)
        return JSON.parse(wrapper_payload) if wrapper_payload.is_a?(String)

        return parsed_params
      end

      raw_body.present? ? JSON.parse(raw_body) : nil
    end

    def github_event_header
      request.headers["X-GitHub-Event"].presence ||
        request.get_header("HTTP_X_GITHUB_EVENT").presence
    end
  end
end

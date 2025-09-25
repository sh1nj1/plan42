module Github
  class WebhooksController < ActionController::API
    def create
      event = request.headers["X-GitHub-Event"]
      raw_body = request.raw_post.presence || request.body.read
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
  end
end

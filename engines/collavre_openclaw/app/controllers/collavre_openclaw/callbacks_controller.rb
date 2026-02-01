module CollavreOpenclaw
  class CallbacksController < ApplicationController
    skip_forgery_protection only: :create
    allow_unauthenticated_access only: :create

    # Handle JSON parsing errors at Rails level
    rescue_from ActionDispatch::Http::Parameters::ParseError do |_exception|
      render json: { error: "Invalid JSON" }, status: :bad_request
    end

    def create
      account = OpenclawAccount.find_by(id: params[:account_id])

      unless account
        render json: { error: "Account not found" }, status: :not_found
        return
      end

      # Authenticate the request
      unless authenticated?(account)
        render json: { error: "Unauthorized" }, status: :unauthorized
        return
      end

      # Process the callback payload
      payload = JSON.parse(request.raw_post, symbolize_names: true)
      CallbackProcessorJob.perform_later(account.id, payload.deep_stringify_keys)

      head :ok
    rescue JSON::ParserError
      render json: { error: "Invalid JSON" }, status: :bad_request
    end

    private

    # Support multiple authentication methods
    def authenticated?(account)
      # If no api_token configured, allow (not recommended for production)
      return true if account.api_token.blank?

      # Method 1: HMAC Signature (X-OpenClaw-Signature header)
      return true if valid_signature?(account)

      # Method 2: Bearer Token (Authorization header)
      return true if valid_bearer_token?(account)

      false
    end

    def valid_signature?(account)
      signature = request.headers["X-OpenClaw-Signature"]
      return false if signature.blank?

      body = request.raw_post
      expected = OpenSSL::HMAC.hexdigest("SHA256", account.api_token, body)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def valid_bearer_token?(account)
      auth_header = request.headers["Authorization"]
      return false if auth_header.blank?

      token = auth_header.to_s.sub(/^Bearer\s+/i, "")
      return false if token.blank?

      ActiveSupport::SecurityUtils.secure_compare(account.api_token, token)
    end
  end
end

module CollavreOpenclaw
  class CallbacksController < ApplicationController
    skip_forgery_protection only: :create
    allow_unauthenticated_access only: :create

    def create
      account = OpenclawAccount.find_by(id: params[:account_id])

      unless account
        render json: { error: "Account not found" }, status: :not_found
        return
      end

      # Verify webhook signature if api_token is set
      if account.api_token.present?
        unless valid_signature?(account)
          render json: { error: "Invalid signature" }, status: :unauthorized
          return
        end
      end

      # Process the callback payload
      payload = JSON.parse(request.raw_post, symbolize_names: true)
      CallbackProcessorJob.perform_later(account.id, payload)

      head :ok
    rescue JSON::ParserError
      render json: { error: "Invalid JSON" }, status: :bad_request
    end

    private

    def valid_signature?(account)
      signature = request.headers["X-OpenClaw-Signature"]
      return false if signature.blank?

      body = request.raw_post
      expected = OpenSSL::HMAC.hexdigest("SHA256", account.api_token, body)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end
  end
end

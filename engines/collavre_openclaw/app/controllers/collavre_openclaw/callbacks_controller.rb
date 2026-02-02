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

      # Parse payload first
      begin
        payload = JSON.parse(request.raw_post, symbolize_names: true)
      rescue JSON::ParserError
        render json: { error: "Invalid JSON" }, status: :bad_request
        return
      end

      # Authenticate the request
      auth_result = authenticate_request(account, payload)
      unless auth_result[:success]
        render json: { error: auth_result[:error] }, status: :unauthorized
        return
      end

      # Merge context from pending callback if nonce was used
      if auth_result[:pending_callback]
        payload = merge_pending_callback_context(payload, auth_result[:pending_callback])
      end

      # Process the callback payload
      CallbackProcessorJob.perform_later(account.id, payload.deep_stringify_keys)

      head :ok
    end

    private

    # Authenticate using multiple methods (in priority order)
    def authenticate_request(account, payload)
      # Method 1: Nonce verification (most secure, preferred)
      nonce = payload[:nonce] || payload[:callback_nonce]
      if nonce.present?
        pending = PendingCallback.verify_and_consume!(nonce)
        if pending && pending.openclaw_account_id == account.id
          return { success: true, pending_callback: pending }
        elsif nonce.present?
          # Nonce provided but invalid
          return { success: false, error: "Invalid or expired nonce" }
        end
      end

      # Method 2: HMAC Signature (for backward compatibility)
      if valid_signature?(account)
        return { success: true }
      end

      # Method 3: Bearer Token (for backward compatibility)
      if valid_bearer_token?(account)
        return { success: true }
      end

      # Method 4: No auth required if account has no token set
      if account.api_key.blank?
        return { success: true }
      end

      { success: false, error: "Unauthorized" }
    end

    def merge_pending_callback_context(payload, pending)
      # Add context from pending callback
      payload[:context] ||= {}
      payload[:context][:creative_id] ||= pending.creative_id
      payload[:context][:comment_id] ||= pending.comment_id
      payload[:context][:thread_id] ||= pending.thread_id

      # Merge any extra context stored in pending callback
      if pending.context.present?
        payload[:context].merge!(pending.context.deep_symbolize_keys)
      end

      payload
    end

    def valid_signature?(account)
      return false if account.api_key.blank?

      signature = request.headers["X-OpenClaw-Signature"]
      return false if signature.blank?

      body = request.raw_post
      expected = OpenSSL::HMAC.hexdigest("SHA256", account.api_key, body)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def valid_bearer_token?(account)
      return false if account.api_key.blank?

      auth_header = request.headers["Authorization"]
      return false if auth_header.blank?

      token = auth_header.to_s.sub(/^Bearer\s+/i, "")
      return false if token.blank?

      ActiveSupport::SecurityUtils.secure_compare(account.api_key, token)
    end
  end
end

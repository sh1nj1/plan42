module CollavreOpenclaw
  class CallbacksController < ApplicationController
    skip_forgery_protection only: :create
    allow_unauthenticated_access only: :create

    # Handle JSON parsing errors at Rails level
    rescue_from ActionDispatch::Http::Parameters::ParseError do |_exception|
      render json: { error: "Invalid JSON" }, status: :bad_request
    end

    def create
      user = User.find_by(id: params[:user_id])

      unless user
        render json: { error: "User not found" }, status: :not_found
        return
      end

      # Parse payload first
      begin
        payload = JSON.parse(request.raw_post, symbolize_names: true)
      rescue JSON::ParserError
        render json: { error: "Invalid JSON" }, status: :bad_request
        return
      end

      # Authenticate the request via nonce
      auth_result = authenticate_request(user, payload)
      unless auth_result[:success]
        render json: { error: auth_result[:error] }, status: :unauthorized
        return
      end

      # Merge context from pending callback if nonce was used
      if auth_result[:pending_callback]
        payload = merge_pending_callback_context(payload, auth_result[:pending_callback])
      end

      # Process the callback payload
      CallbackProcessorJob.perform_later(user.id, payload.deep_stringify_keys)

      head :ok
    end

    private

    # Authenticate using nonce verification
    def authenticate_request(user, payload)
      # Nonce verification (required for callbacks)
      nonce = payload[:nonce] || payload[:callback_nonce]
      if nonce.present?
        pending = PendingCallback.verify_and_consume!(nonce)
        if pending && pending.user_id == user.id
          return { success: true, pending_callback: pending }
        else
          return { success: false, error: "Invalid or expired nonce" }
        end
      end

      { success: false, error: "Nonce required for callback authentication" }
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
  end
end

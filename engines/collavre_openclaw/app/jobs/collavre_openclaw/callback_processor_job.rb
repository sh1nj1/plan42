module CollavreOpenclaw
  class CallbackProcessorJob < ApplicationJob
    queue_as :default

    def perform(user_id, payload)
      @user = User.find_by(id: user_id)
      return unless @user

      # Symbolize keys for consistent access
      payload = payload.deep_symbolize_keys

      Rails.logger.info("[CollavreOpenclaw] Processing callback for user #{user_id}, type: #{payload[:type]}")

      case payload[:type]&.to_s
      when "response"
        handle_response(payload)
      when "proactive"
        handle_proactive(payload)
      when "error"
        handle_error(payload)
      else
        # Default: try to handle as response for backward compatibility
        if payload[:content].present? || payload[:message].present?
          handle_response(payload)
        else
          Rails.logger.warn("[CollavreOpenclaw] Unknown callback type: #{payload[:type]}")
        end
      end
    end

    private

    # Handle async response to a previous request
    def handle_response(payload)
      context = payload[:context] || {}
      creative_id = context[:creative_id]
      comment_id = context[:comment_id]
      content = payload[:content] || payload[:message]

      if comment_id.present?
        # Update existing comment (streaming completion)
        comment = Collavre::Comment.find_by(id: comment_id)
        if comment && content.present?
          comment.update!(content: content)
          Rails.logger.info("[CollavreOpenclaw] Updated comment #{comment_id} with callback response")
        end
      elsif creative_id.present? && content.present?
        # Create new comment on the creative
        create_ai_comment(creative_id, content, context)
      end
    end

    # Handle proactive message from OpenClaw (agent-initiated)
    def handle_proactive(payload)
      creative_id = payload[:creative_id] || payload.dig(:context, :creative_id)
      content = payload[:content] || payload[:message]
      thread_id = payload[:thread_id] || payload.dig(:context, :thread_id)
      parent_comment_id = payload[:parent_comment_id] || payload.dig(:context, :parent_comment_id)

      unless creative_id.present?
        Rails.logger.error("[CollavreOpenclaw] Proactive message missing creative_id")
        return
      end

      unless content.present?
        Rails.logger.error("[CollavreOpenclaw] Proactive message missing content")
        return
      end

      context = {
        thread_id: thread_id,
        parent_comment_id: parent_comment_id,
        proactive: true
      }

      create_ai_comment(creative_id, content, context)
    end

    def handle_error(payload)
      error_message = payload[:error] || payload[:message] || "Unknown error"
      Rails.logger.error("[CollavreOpenclaw] Callback error: #{error_message}")

      # Optionally notify the creative if context is available
      creative_id = payload.dig(:context, :creative_id)
      if creative_id.present?
        create_ai_comment(
          creative_id,
          "⚠️ OpenClaw Error: #{error_message}",
          { error: true }
        )
      end
    end

    def create_ai_comment(creative_id, content, context = {})
      creative = Collavre::Creative.find_by(id: creative_id)
      unless creative
        Rails.logger.error("[CollavreOpenclaw] Creative not found: #{creative_id}")
        return
      end

      # Build comment attributes
      comment_attrs = {
        creative: creative.effective_origin,
        user: @user,
        content: content,
        private: false
      }

      # Handle topic/thread if specified
      if context[:thread_id].present?
        topic = Collavre::Topic.find_by(id: context[:thread_id])
        comment_attrs[:topic] = topic if topic
      end

      comment = Collavre::Comment.create!(comment_attrs)
      Rails.logger.info("[CollavreOpenclaw] Created AI comment #{comment.id} on creative #{creative_id}")

      comment
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[CollavreOpenclaw] Failed to create comment: #{e.message}")
      nil
    end
  end
end

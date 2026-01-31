module CollavreOpenclaw
  class CallbackProcessorJob < ApplicationJob
    queue_as :default

    def perform(account_id, payload)
      account = OpenclawAccount.find_by(id: account_id)
      return unless account

      Rails.logger.info("[CollavreOpenclaw] Processing callback for account #{account_id}")

      # Handle different callback types
      case payload[:type]
      when "response"
        handle_response(account, payload)
      when "error"
        handle_error(account, payload)
      else
        Rails.logger.warn("[CollavreOpenclaw] Unknown callback type: #{payload[:type]}")
      end
    end

    private

    def handle_response(account, payload)
      # Find the task/comment that this response is for
      task_id = payload.dig(:context, :task_id)
      comment_id = payload.dig(:context, :comment_id)

      if comment_id
        comment = Collavre::Comment.find_by(id: comment_id)
        if comment && payload[:content].present?
          comment.update!(content: payload[:content])
          Rails.logger.info("[CollavreOpenclaw] Updated comment #{comment_id} with callback response")
        end
      end
    end

    def handle_error(account, payload)
      Rails.logger.error("[CollavreOpenclaw] Callback error: #{payload[:error]}")
    end
  end
end

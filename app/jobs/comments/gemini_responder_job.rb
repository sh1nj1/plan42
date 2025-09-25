module Comments
  class GeminiResponderJob < ApplicationJob
    queue_as :default

    def perform(comment_id, creative_id)
      comment = Comment.find_by(id: comment_id)
      creative = Creative.find_by(id: creative_id)&.effective_origin
      return unless comment && creative

      Comments::GeminiResponder.new(comment: comment, creative: creative).call
    end
  end
end

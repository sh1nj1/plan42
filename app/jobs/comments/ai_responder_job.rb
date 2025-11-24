module Comments
  class AiResponderJob < ApplicationJob
    queue_as :default

    def perform(comment_id, creative_id)
      comment = Comment.find_by(id: comment_id)
      creative = Creative.find_by(id: creative_id)
      return unless comment && creative

      Comments::AiResponder.new(comment: comment, creative: creative).call
    end
  end
end

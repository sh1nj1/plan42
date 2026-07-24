# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Mobile
        # A plain mic press (no message selected) routes here: the utterance
        # starts a new piece of work in the user's Inbox#Main, exactly like
        # typing in the inbox chat — dispatch then matches an agent via
        # routing_expression. Replies to a SPECIFIC message go through
        # agent_events#respond instead (they carry the target event id).
        class VoiceCommandsController < BaseController
          def create
            text = params[:text].to_s.strip
            return render_speak(:empty_response, action: { type: "noop" }) if text.blank?

            inbox = Collavre::Creative.inbox_for(current_user)
            comment = inbox.comments.create!(content: text, user: current_user)
            render_speak(:sent, action: { type: "message_sent", comment_id: comment.id })
          end
        end
      end
    end
  end
end

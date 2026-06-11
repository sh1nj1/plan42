# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Mobile
        # The heart of the loop. GET surfaces pending approvals (+ recent agent
        # replies) with a stable spoken ref number and a decision-ready summary.
        # POST :id/respond branches on the referenced event KIND:
        #   (A) approval/permission comment → the spoken response is a BUTTON
        #       press (allow|deny) → decide_claude_channel_permission! + relay.
        #   (B) ordinary agent message → the spoken response is FREE TEXT passed
        #       verbatim back to the agent as a reply comment (no server parsing).
        class AgentEventsController < BaseController
          def index
            since = parse_since(params[:since])

            approvals = pending_approvals
            approval_refs = approvals.to_h { |c| [ c.id, registry.ref_for_approval(c, label: label_for_topic(c.topic_id), topic_id: c.topic_id) ] }

            running = running_tasks.to_a
            running.each { |task| registry.ref_for_session(task.topic_id, label: task.name) }

            replies = agent_replies(since)

            registry.reconcile!(
              active_comment_ids: approvals.map(&:id),
              active_topic_ids: running.map(&:topic_id)
            )

            events = approvals.map do |c|
              ref = approval_refs[c.id]
              {
                id: c.id, ref: ref.ref_number, type: "approval_requested",
                title: ref.label,
                summary: summarizer.approval_summary(ref_number: ref.ref_number, comment: c, label: ref.label),
                speak: true, requires_response: true, topic_id: c.topic_id,
                created_at: c.created_at.iso8601
              }
            end

            events += replies.map do |c|
              ref = registry.ref_for_session(c.topic_id, label: label_for_topic(c.topic_id))
              {
                id: c.id, ref: ref.ref_number, type: "agent_reply",
                title: ref.label,
                summary: summarizer.reply_summary(ref_number: ref.ref_number, content: c.content, label: ref.label),
                speak: true, requires_response: c.content.to_s.strip.end_with?("?"),
                topic_id: c.topic_id, created_at: c.created_at.iso8601
              }
            end

            render json: events.sort_by { |e| e[:created_at] }
          end

          def respond
            comment = Collavre::Comment.find_by(id: params[:id])
            unless comment && authorized_comment?(comment)
              return render json: { error: "Event not found" }, status: :not_found
            end

            if comment.claude_channel_permission?
              decide_on(comment)
            else
              relay_free_text(comment)
            end
          end

          private

          def parse_since(value)
            return nil if value.blank?

            Time.iso8601(value.to_s)
          rescue ArgumentError
            nil
          end

          def agent_replies(since)
            return Collavre::Comment.none if agent_ids.empty?

            scope = Collavre::Comment.where(user_id: agent_ids, action: nil)
                                     .where.not(topic_id: nil)
                                     .order(:created_at)
                                     .limit(50)
            scope = scope.where("comments.created_at > ?", since) if since
            scope
          end

          def authorized_comment?(comment)
            return true if comment.approver_id == current_user.id

            author = comment.user
            author.respond_to?(:created_by_id) && agent_ids.include?(author.id)
          end

          # (A) bounded decision: spoken response IS the approve/deny button.
          def decide_on(comment)
            behavior = behavior_from(params[:response])

            unless %w[allow deny].include?(behavior)
              return render_speak(:clarify_decision, action: { type: "needs_clarification", comment_id: comment.id })
            end

            comment.decide_claude_channel_permission!(behavior, by: current_user)
            comment.broadcast_claude_channel_permission_decision(behavior)
            resolve_ref_for(comment)

            render_speak(
              behavior == "allow" ? :approved : :denied,
              action: { type: behavior == "allow" ? "approved" : "denied", comment_id: comment.id }
            )
          rescue Collavre::Comment::ClaudeChannelPermission::AlreadyDecided
            render_speak(:already_decided, action: { type: "already_decided", comment_id: comment.id })
          end

          # (B) free-form: relay the utterance verbatim as a human reply.
          def relay_free_text(comment)
            text = params[:response].to_s.strip
            return render_speak(:empty_response, action: { type: "noop" }) if text.blank?

            topic = comment.topic
            creative = topic&.creative&.effective_origin || comment.creative
            reply = creative.comments.create!(content: text, user: current_user, topic: topic, quoted_comment: comment)

            render_speak(:relayed, action: { type: "relayed", comment_id: reply.id, topic_id: topic&.id })
          end

          def behavior_from(response)
            case response.to_s.strip.downcase
            when "approve", "allow", "yes" then "allow"
            when "deny", "reject", "no"    then "deny"
            else
              res = command_resolver.resolve(response.to_s)
              res.behavior if %w[approve deny].include?(res.intent)
            end
          end

          def resolve_ref_for(comment)
            ref = Collavre::MobileVoiceRef.for_device(current_user.id, device_id)
                                          .active.find_by(target_comment_id: comment.id)
            ref&.resolve!
          end
        end
      end
    end
  end
end

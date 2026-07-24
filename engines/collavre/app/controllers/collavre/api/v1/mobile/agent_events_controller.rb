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
          # Spoken decision verbs. The app no longer addresses approvals by
          # ordinal, so a reply to an approval event is just an allow/deny verb;
          # anything else asks for clarification rather than firing a decision.
          APPROVE = /(승인|허용|적용|approve|allow|confirm|네|좋아|오케이|\bok\b|\byes\b)/i
          DENY    = /(거절|거부|반려|deny|reject|취소|아니|\bno\b)/i

          def index
            approvals = pending_approvals
            notices = system_inbox_messages

            # Every undecided approval is emitted on every poll — the server keeps
            # no per-client cursor. Re-speaking is prevented on the CLIENT (an
            # in-memory "already spoken" set), the same at-least-once shape as
            # notices: a pending approval keeps surfacing until it is decided
            # (which clears it from pending_approvals) or the app restarts (when a
            # still-pending approval SHOULD be re-surfaced). The old `since` cursor
            # filtered here, but a batch high-water-mark could burn past an approval
            # whose created_at trailed a newer notice, losing it forever.
            events = approvals.map do |c|
              {
                id: c.id, type: "approval_requested",
                title: title_for_topic(c.topic_id),
                summary: summarizer.approval_summary(comment: c, label: label_for_topic(c.topic_id)),
                speak: true, requires_response: true, topic_id: c.topic_id,
                created_at: c.created_at.iso8601(6)
              }
            end

            events += notices.map do |c|
              # The notice stands in for the origin comment it quotes; the app
              # lists/reads it against the ORIGIN thread and replies route there.
              origin_topic_id = c.quoted_comment&.topic_id || c.topic_id
              {
                id: c.id, type: "agent_reply",
                title: title_for_topic(origin_topic_id),
                summary: speakable(c.content),
                speak: true, requires_response: c.quoted_comment_id.present?,
                topic_id: origin_topic_id, created_at: c.created_at.iso8601(6)
              }
            end

            render json: events.sort_by { |e| e[:created_at] }
          end

          def respond
            comment = Collavre::Comment.find_by(id: params[:id])
            unless comment && authorized_comment?(comment)
              return render json: { error: "Event not found" }, status: :not_found
            end

            # Acting on a notice means the user has heard it — clear it from the
            # unread inbox set so it isn't read again on the next poll. The app can
            # hold that mark back (defer_read) when it answers a notice OUT OF ORDER:
            # the pointer is a single forward-only high-water-mark, so marking this
            # one claims every older unread notice with it. The app then sends the
            # mark itself (POST :id/read) once nothing older is still owed a reading.
            # Deferring costs at most a repeated reading if the app dies before that;
            # not deferring costs the older notices outright.
            mark_inbox_read(comment) unless defer_read?

            if comment.claude_channel_permission?
              decide_on(comment)
            else
              relay_free_text(comment)
            end
          end

          # The app calls this when it finishes reading a message ALOUD (whether or
          # not the user then replies). Reading = hearing it, so the inbox read
          # pointer advances and the notice stops surfacing — the SAME read-state
          # the inbox badge uses. A crash before this call leaves the notice unread,
          # so the next poll re-reads it (at-least-once, not the lossy old cursor).
          def read
            comment = Collavre::Comment.find_by(id: params[:id])
            unless comment && authorized_comment?(comment)
              return render json: { error: "Event not found" }, status: :not_found
            end

            mark_inbox_read(comment)
            head :ok
          end

          private

          # Opt-in only: a client that does not send the flag (or any older build)
          # keeps the previous mark-on-respond behaviour.
          def defer_read?
            ActiveModel::Type::Boolean.new.cast(params[:defer_read]) == true
          end

          # The user's Inbox → System topic is the per-user alarm stream: mentions,
          # agent replies, share notices, … land here as system-authored
          # (user_id: nil) comments that QUOTE the origin comment. This is the
          # canonical, agent-ownership-independent feed the voice loop reads aloud.
          #
          # Emission is gated by the inbox's OWN read-state — the CommentReadPointer
          # (comments with id > last_read_comment_id are unread) that also drives the
          # inbox badge — NOT by the client's `since` cursor. A `since` cursor is a
          # fetch-time high-water-mark: any notice fetched-but-never-spoken (crash,
          # background, busy queue, restart) gets burned past and is lost forever,
          # even though it stays unread in the inbox. Driving off the read pointer
          # makes "unread in the inbox" and "read aloud by the app" the same set; the
          # app marks a notice read (POST :id/read) only after actually speaking it.
          def system_inbox_messages
            inbox = current_user_inbox or return []
            last_read = inbox_read_pointer&.last_read_comment_id || 0

            scope = Collavre::Comment.where(creative_id: inbox.id, topic_id: inbox.system_topic.id)
                                     .where("comments.id > ?", last_read)
                                     .order(:id)
                                     .limit(50)
            # Approval prompts are surfaced (actionably) by pending_approvals; their
            # System-topic FYI duplicate must not be read a second time.
            scope.reject { |c| c.quoted_comment&.claude_channel_permission? }
          end

          def inbox_read_pointer
            inbox = current_user_inbox or return nil

            Collavre::CommentReadPointer.find_by(user: current_user, creative: inbox)
          end

          # Advance the inbox read pointer to (at least) this notice — forward-only,
          # so a later message is never un-read. Only inbox-creative comments move the
          # inbox pointer; calling this for an approval (which lives in the origin
          # creative and is owned by pending_approvals) is a harmless no-op.
          def mark_inbox_read(comment)
            inbox = current_user_inbox or return
            return unless comment.creative_id == inbox.id

            pointer = Collavre::CommentReadPointer.find_or_initialize_by(user: current_user, creative: inbox)
            new_id = [ pointer.last_read_comment_id || 0, comment.id ].max
            pointer.update(last_read_comment_id: new_id)
          end

          def current_user_inbox
            return @current_user_inbox if defined?(@current_user_inbox)

            @current_user_inbox = Collavre::Creative.inbox_for(current_user)
          end

          # Read the whole message aloud, but spoken: strip markdown link syntax to
          # its text and collapse whitespace so TTS doesn't read raw URLs.
          def speakable(text)
            text.to_s.gsub(/\[([^\]]+)\]\([^)]*\)/, '\1').gsub(/\s+/, " ").strip
          end

          def authorized_comment?(comment)
            return true if comment.approver_id == current_user.id
            return true if own_inbox_notice?(comment)

            author = comment.user
            author.respond_to?(:created_by_id) && agent_ids.include?(author.id)
          end

          # A system-authored notice in the caller's own Inbox#System topic. Owning
          # the inbox is the authorization proof (the notice has no approver/author).
          def own_inbox_notice?(comment)
            inbox = current_user_inbox or return false

            comment.user_id.nil? &&
              comment.creative_id == inbox.id &&
              comment.topic_id == inbox.system_topic.id
          end

          # (A) bounded decision: spoken response IS the approve/deny button.
          def decide_on(comment)
            behavior = behavior_from(params[:response])

            unless %w[allow deny].include?(behavior)
              return render_speak(:clarify_decision, action: { type: "needs_clarification", comment_id: comment.id })
            end

            case decide_permission(comment, behavior)
            when :unauthorized
              render_speak(:not_authorized, action: { type: "not_authorized", comment_id: comment.id }, status: :forbidden)
            when :already_decided
              render_speak(:already_decided, action: { type: "already_decided", comment_id: comment.id })
            else
              render_speak(
                behavior == "allow" ? :approved : :denied,
                action: { type: behavior == "allow" ? "approved" : "denied", comment_id: comment.id }
              )
            end
          end

          # (B) free-form: relay the utterance verbatim as a human reply.
          def relay_free_text(comment)
            text = params[:response].to_s.strip
            return render_speak(:empty_response, action: { type: "noop" }) if text.blank?

            # A System-inbox notice is a stand-in for the origin comment it quotes;
            # the reply must land on that origin thread (the System topic itself
            # never dispatches AI), not on the notice.
            target = comment.quoted_comment || comment
            topic = target.topic
            creative = topic&.creative&.effective_origin || target.creative
            # quoted_comment threads the reply to the message being answered, but
            # review_type: :question keeps review_message? false — otherwise the
            # agent's response would update the quoted comment IN PLACE (review flow)
            # instead of posting a new reply, so no new comment is created and the
            # Inbox#System alarm never fires. Same guard as InboxReplyService (#1301).
            reply = creative.comments.create!(
              content: text, user: current_user, topic: topic,
              quoted_comment: target, review_type: :question
            )

            render_speak(:relayed, action: { type: "relayed", comment_id: reply.id, topic_id: topic&.id })
          end

          def behavior_from(response)
            text = response.to_s.strip
            return "allow" if text.match?(APPROVE)
            return "deny"  if text.match?(DENY)

            nil
          end
        end
      end
    end
  end
end

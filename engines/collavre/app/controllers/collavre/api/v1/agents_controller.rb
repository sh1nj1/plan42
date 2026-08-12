# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class AgentsController < BaseController
        # POST /api/v1/agent/register
        # Registers a Claude Code session, separating two identities:
        #   - Agent (agent_name): the user-facing unit. One shared ai_user per
        #     (human, agent_name). Without an explicit AGENT_NAME the plugin
        #     sends a default name so every session collapses onto one agent.
        #   - Session (session_id): one Topic per Claude Code session, keyed by
        #     a stable id (derived per cwd by the plugin, stable across
        #     --resume). Multiple session topics can share one primary_agent.
        #
        # Back-compat: older plugins send only :name. It is treated as BOTH the
        # agent and the session identity, reproducing the prior
        # one-agent-one-topic-per-name behavior.
        def register
          agent_name = params[:agent_name].to_s.strip
          session_id = params[:session_id].to_s.strip
          legacy_name = params[:name].to_s.strip
          agent_name = legacy_name if agent_name.blank?
          session_id = legacy_name if session_id.blank?

          if agent_name.blank? || session_id.blank?
            render json: { error: "name (or agent_name and session_id) is required" },
                   status: :unprocessable_entity
            return
          end

          ai_user = session_provisioner.find_or_create_agent(agent_name)
          unless ai_user
            render json: { error: "Session agent email is already in use by a different account" }, status: :conflict
            return
          end

          inbox = Creative.inbox_for(current_user)
          topic = session_provisioner.find_or_create_topic(inbox, ai_user, session_id, params[:session_label])
          topic.unarchive! if topic.archived?
          topic.set_primary_agent!(ai_user)

          # find_or_create_by! keeps the SELECT-first path (so a sequential
          # re-register reuses the existing share without tripping CreativeShare's
          # model-level user_id/creative_id uniqueness validation). But concurrent
          # sibling registrations can both pass that SELECT before either commits;
          # the loser then hits the DB unique index. Rescue that race and re-find
          # instead of surfacing a 500/conflict.
          begin
            CreativeShare.find_or_create_by!(creative: inbox, user: ai_user) do |s|
              s.permission = :feedback
              s.shared_by = current_user
            end
          rescue ActiveRecord::RecordNotUnique
            CreativeShare.find_by!(creative: inbox, user: ai_user)
          end

          render json: {
            agent_id: ai_user.id,
            agent_name: ai_user.name,
            topic_id: topic.id,
            topic_name: topic.name,
            session_id: session_id,
            inbox_creative_id: inbox.id,
            ws_url: "/cable"
          }, status: :ok
        end

        # DELETE /api/v1/agent/:id
        # Archives the agent's topic (session ended).
        # topic_id is required: register reuses the same ai_user across all
        # sessions for the same human, so the primary_agent association alone
        # cannot identify which session is ending. Without an explicit topic_id
        # we could archive a sibling session's active topic.
        def destroy
          ai_user = User.find_by(id: params[:id])
          unless ai_user&.ai_user? && ai_user.created_by_id == current_user.id
            render json: { error: "Agent not found" }, status: :not_found
            return
          end

          if params[:topic_id].blank?
            render json: { error: "topic_id is required" }, status: :unprocessable_entity
            return
          end

          inbox = Creative.inbox_for(current_user)
          topic = inbox.topics.active.find_by(id: params[:topic_id])
          # Ensure the topic actually belongs to this agent so a mismatched
          # topic_id can't archive an unrelated inbox conversation.
          topic = nil unless topic && topic.primary_agent&.id == ai_user.id

          # The plugin closes the WebSocket and IMMEDIATELY calls DELETE, so
          # AgentChannel#unsubscribed may not have dropped this session's presence
          # row yet. Drop it up front — keyed by the ending session's id (sent by
          # the plugin, or derived from the required topic) — so this session's
          # own still-live row cannot masquerade as a live sibling and skip the
          # last-session teardown (which would pin routing_expression on and, if
          # the WS close is never processed, leave nothing to clear it). Done
          # under the agent row lock to serialize against a concurrent subscribe/
          # unsubscribe on the shared agent — the same lock AgentChannel uses.
          exiting_session_id = params[:session_id].presence || topic&.session_id
          last_session = false
          ai_user.with_lock do
            if exiting_session_id.present?
              AgentSubscription
                .where(agent_id: ai_user.id, session_id: exiting_session_id)
                .delete_all
            end

            unless sibling_sessions_live?(ai_user)
              last_session = true
              # Last (or only) session for this agent. Clear routing_expression
              # FIRST so Orchestration::Matcher#match_by_expression stops
              # dispatching new comments to this now-clientless agent while we
              # drain its task graph below; otherwise a comment arriving mid-drain
              # could enqueue a new task right after we cancelled the last one.
              # (Routing is reactivated on the next AgentChannel subscribe, not on
              # re-register.)
              ai_user.update_column(:routing_expression, nil) if ai_user.routing_expression.present?
            end
          end

          if last_session
            # Cancel queued/pending tasks BEFORE draining topic queues. The topic
            # queue (Task.queued_for_topic) is scoped by topic_id, not agent_id,
            # so dequeue_next_for_topic would otherwise flip a queued task for
            # this clientless agent to pending and enqueue AiAgentJob — which then
            # broadcasts to a stream with no subscriber and strands the task in
            # delegated until stuck recovery.
            cancel_pending_tasks_for_session(ai_user)

            # Fail any tasks still delegated to this agent — including dispatches
            # routed to *work* topics outside the registration inbox. With no live
            # session left, agent_id uniquely scopes this agent's delegated work;
            # scoping by topic_id alone would leak the common case (a dispatch on a
            # project topic) until stuck detection times out.
            cancel_delegated_tasks_for_session(ai_user)
          elsif topic
            # One shared agent fans out to many concurrent sessions (the default
            # AGENT_NAME case). Another session is still LIVE, so agent-wide
            # cleanup would clear the shared routing_expression and cancel the
            # sibling's in-flight work — exactly the hazard AgentChannel#unsubscribed
            # guards against via presence. Tear down ONLY this ending session:
            # cancel work on its own topic (whose client is gone, so it would
            # otherwise hold a slot / block the topic queue until stuck recovery).
            # The shared routing and any work on other topics belong to the live
            # sibling and are left untouched.
            cancel_tasks_for_topic(ai_user, topic)
          end
          topic.archive! if topic

          head :no_content
        end

        # POST /api/v1/agent/reply
        # Creates a comment in a topic as the AI agent
        def reply
          topic = Topic.find_by(id: params[:topic_id])
          unless topic
            render json: { error: "Topic not found" }, status: :not_found
            return
          end

          creative = topic.creative&.effective_origin
          unless creative
            render json: { error: "Creative not found" }, status: :not_found
            return
          end

          unless creative.has_permission?(current_user, :feedback)
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          agent = resolve_reply_agent(topic, params[:task_id])
          unless agent
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          # Atomically claim the delegated task BEFORE saving the reply.
          # Two concurrent /reply requests with the same task_id can both
          # pass resolve_reply_agent (which is a read-only scope check) and,
          # without an atomic WHERE status='delegated' transition, both would
          # save separate comments and both would run completion logic —
          # producing duplicate linked replies for one dispatch. Claim first,
          # save second, so the loser sees rows_updated == 0 and bails out
          # before touching the comments table.
          claimed_task = claim_delegated_task(agent, topic, params[:task_id])
          if params[:task_id].present? && claimed_task.nil?
            render json: { error: "Task already completed or not delegated" }, status: :conflict
            return
          end

          comment = creative.comments.build(
            content: params[:text].to_s,
            topic: topic,
            user: agent,
            skip_default_user: true,
            skip_dispatch: true
          )

          if comment.save
            task_claim_service.finalize(agent: agent, task: claimed_task, comment: comment) if claimed_task
            dispatch_a2a(agent, comment, task: claimed_task)
            render json: { comment_id: comment.id }, status: :created
          else
            # Restore the dispatch so the MCP client can retry — the failure
            # is text-level (validation), not task-level.
            claimed_task&.update!(status: "delegated")
            render json: { errors: comment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/agent/notify
        # Posts an out-of-band informational comment to a topic as the agent
        # WITHOUT completing any task or dispatching. Unlike /reply, this never
        # touches the task graph: it surfaces notices (e.g. native channel
        # permission prompts relayed by Claude Code mid-turn) into the topic
        # chat while the originating task stays in flight. skip_dispatch avoids
        # spawning a new delegated task for the agent's own message.
        def notify
          topic = Topic.find_by(id: params[:topic_id])
          unless topic
            render json: { error: "Topic not found" }, status: :not_found
            return
          end

          creative = topic.creative&.effective_origin
          unless creative
            render json: { error: "Creative not found" }, status: :not_found
            return
          end

          unless creative.has_permission?(current_user, :feedback)
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          # The poster must be this session's own Claude Channel agent, owned by
          # the token holder — so /notify can't be used to ventriloquize an
          # unrelated agent or post into a topic the caller doesn't drive.
          agent = resolve_notify_agent(topic, params[:task_id])
          unless agent
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          comment =
            if params[:permission_request_id].present?
              build_permission_comment(creative, topic, agent)
            else
              creative.comments.build(
                content: params[:text].to_s,
                topic: topic,
                user: agent,
                skip_default_user: true,
                skip_dispatch: true
              )
            end

          if comment.save
            park_pending_permission(topic, agent, params[:task_id], params[:permission_request_id])
            render json: { comment_id: comment.id }, status: :created
          else
            render json: { errors: comment.errors.full_messages }, status: :unprocessable_entity
          end
        end
        private

        # Build a structured tool-permission comment that reuses the native
        # approval UI (approver gate + approve/deny buttons). The prompt text is
        # rendered server-side via I18n (localized for the viewer), not formatted
        # by the plugin. The action payload carries the request_id so the
        # eventual approve/deny relays the exact decision to the suspended
        # session. approver is the token holder driving this Claude session — the
        # only human who should resolve its prompts.
        def build_permission_comment(creative, topic, agent)
          tool_name = params[:tool_name].to_s.strip.presence || "tool"
          args_raw = sanitize_permission_arguments(params[:arguments])
          description = params[:description].to_s.strip

          action_payload = {
            "action" => Comment::ClaudeChannelPermission::ACTION_TYPE,
            "request_id" => params[:permission_request_id].to_s,
            "tool_name" => tool_name,
            "description" => description,
            "arguments" => args_raw
          }

          # The API base controller authenticates the bearer token but does not
          # run the host app's locale switching, so I18n.locale is the process
          # default here. Render the persisted prompt in the token holder's
          # locale explicitly — they are the approver who will read it.
          content = I18n.with_locale(current_user&.locale.presence || I18n.default_locale) do
            I18n.t(
              "collavre.claude_channel.permission.message",
              tool_name: format_permission_tool_name(tool_name),
              description: format_permission_description(description),
              arguments: format_permission_arguments(args_raw)
            )
          end

          creative.comments.build(
            content: content,
            topic: topic,
            user: agent,
            approver: current_user,
            action: JSON.pretty_generate(action_payload),
            skip_default_user: true,
            skip_dispatch: true
          )
        end

        # Coerce the arguments param into a JSON-safe value: a permitted Hash, a
        # plain string, or nil. ActionController::Parameters must be unwrapped or
        # JSON.pretty_generate raises on unpermitted parameters.
        def sanitize_permission_arguments(arguments)
          return nil if arguments.blank?

          arguments.respond_to?(:to_unsafe_h) ? arguments.to_unsafe_h : arguments
        end

        # Render the (already sanitized) tool arguments for the prompt body. The
        # result is interpolated inside a ```json fence and the comment is later
        # passed through renderCommentMarkdown, so the value must never be able to
        # close that fence. A string input_preview (the documented shape for many
        # tools, e.g. a Bash command) is therefore JSON-serialized rather than
        # emitted raw: that escapes embedded newlines to \n, collapsing it to a
        # single line so no payload line can begin a ``` delimiter and break out
        # into live markdown that misleads the approver.
        def format_permission_arguments(arguments)
          return I18n.t("collavre.claude_channel.permission.no_arguments") if arguments.blank?

          JSON.pretty_generate(arguments)
        end

        # Render the optional human-readable permission summary Claude Code sends
        # alongside the structured fields. Absent for most tools, so it collapses
        # to an empty string (no stray blockquote); when present it is the only
        # plain-language description of what the approver is allowing.
        def format_permission_description(description)
          return "" if description.blank?

          # The description renders into a "> %{text}" blockquote, so any newline
          # would drop the remainder onto a fresh line where it could open a
          # heading or ```fence and escape into live markdown. Flatten line breaks
          # to whitespace so the whole summary stays inside the one blockquote line
          # (inline backticks there are harmless — a fence must start a line).
          flattened = description.gsub(/\s*\R\s*/, " ").strip
          I18n.t("collavre.claude_channel.permission.description", text: flattened)
        end

        # Render the tool name for the prompt. Unlike description/arguments it is
        # interpolated into a "**%{tool_name}**" emphasis span and the comment is
        # later passed through renderCommentMarkdown, so an unescaped value (e.g. a
        # third-party MCP tool name) could close the surrounding "**", or — via an
        # embedded newline — start a fresh-line heading/fence and misrepresent which
        # tool the approver is authorizing. Flatten line breaks to whitespace and
        # backslash-escape markdown metacharacters so the name always renders
        # literally. The raw name is still kept in the action payload.
        def format_permission_tool_name(tool_name)
          flattened = tool_name.gsub(/\s*\R\s*/, " ").strip
          flattened.gsub(/([\\`*_{}\[\]()#+\-.!~>|<])/) { "\\#{$1}" }
        end

        # When the relayed comment is a native tool-permission prompt (carries a
        # permission_request_id), park the in-flight dispatch as "awaiting a
        # decision" by stamping pending_tool_call on its delegated task.
        # Comment#dispatch_to_orchestration then relays the human's subsequent
        # allow/deny straight to this suspended session instead of queuing it
        # behind the delegated topic slot (which would deadlock — the task holds
        # the slot it is itself waiting to be unblocked on). Cleared when the
        # task is completed (/reply) or cancelled (unregister/stuck recovery).
        def park_pending_permission(topic, agent, requested_task_id, request_id)
          return if request_id.blank? || requested_task_id.blank?

          task = Task.where(topic_id: topic.id, status: "delegated", agent_id: agent.id)
                     .find_by(id: requested_task_id)
          task&.update_column(:pending_tool_call, {
            "request_id" => request_id.to_s,
            "requested_at" => Time.current.iso8601
          })
        end

        # Identify which Claude Channel agent a /notify posts as.
        #
        # Mirrors resolve_reply_agent's task_id-first resolution but never
        # touches the task graph (notify only authorizes, it does not complete).
        # A native permission prompt can be raised during a dispatch that
        # selected this session via routing_expression on a *work* topic whose
        # primary_agent is unset or a different agent (the case documented on
        # resolve_reply_agent). The echoed active-dispatch task_id authorizes
        # the dispatched session agent directly; without it the topic-
        # primary_agent gate would 403 and the prompt would never surface in
        # Collavre.
        #
        # task_id absent → fall back to topic.primary_agent (the registration
        # inbox default, where the session IS primary — locally-initiated
        # turns). task_id present-but-unresolved → nil (no fall-through), same
        # as resolve_reply_agent: a present id targeting a vanished/foreign task
        # must not silently post as primary_agent.
        def resolve_notify_agent(topic, requested_task_id)
          if requested_task_id.present?
            task = Task.where(topic_id: topic.id, status: "delegated").find_by(id: requested_task_id)
            agent = task&.agent
            return nil unless agent && agent.claude_channel_agent? && agent.created_by_id == current_user.id

            return agent
          end

          agent = topic.primary_agent
          return agent if agent&.claude_channel_agent? && agent.created_by_id == current_user.id

          nil
        end

        # Identify which Claude Channel agent this reply is for.
        #
        # Prefer the echoed task_id from the dispatch payload: the matcher can
        # route to a Claude Channel agent via routing_expression on a topic
        # whose primary_agent is unset or a different agent (e.g. multiple AI
        # agents share a topic, or this agent only has feedback permission on
        # the creative without being the topic's primary). In those cases the
        # topic.primary_agent gate would 403 the reply and leave the delegated
        # task hanging.
        #
        # When task_id is provided, look it up scoped to this topic and the
        # delegated state, then take the agent from the task. The token holder
        # is still required to own the agent (created_by_id == current_user.id)
        # and the agent must be a Claude Channel agent so this endpoint can't
        # be used to ventriloquize an unrelated AI agent.
        #
        # When task_id is absent, fall back to topic.primary_agent for
        # back-compat with older plugin builds that don't echo task_id.
        #
        # If task_id IS supplied but the delegated task lookup fails (late
        # reply after cancel/timeout, stale id, wrong topic), do NOT fall
        # through to primary_agent — a present-but-unresolved task_id means
        # the client believes it is answering a specific dispatch that no
        # longer exists. Saving the reply against primary_agent would create
        # an unlinked comment while complete_delegated_task finds nothing,
        # potentially duplicating a reply after the task was already
        # completed/cancelled. Return nil so reply renders 403.
        def resolve_reply_agent(topic, requested_task_id)
          if requested_task_id.present?
            task = Task.where(topic_id: topic.id, status: "delegated").find_by(id: requested_task_id)
            agent = task&.agent
            return nil unless agent && agent.claude_channel_agent? && agent.created_by_id == current_user.id

            return agent
          end

          # Legacy fallback (no task_id) must apply the same Claude Channel
          # gate as the task_id path above. Without it, a feedback-permission
          # caller could POST /reply on an ordinary topic whose primary_agent
          # is a normal AI user and save an unlinked comment authored as that
          # agent. Restrict to Claude Channel agents owned by the caller.
          agent = topic.primary_agent
          return agent if agent&.claude_channel_agent? && agent.created_by_id == current_user.id

          nil
        end

        # When an MCP session unregisters, any tasks still in delegated state
        # are abandoned — the client that would have called /reply is gone.
        # Mirror the cancel path so the agent's slot and each topic's queue
        # both free up immediately rather than waiting for stuck detection.
        # Scopes by agent_id only: per-session ai_users mean every delegated
        # task for this agent belongs to this session, on any topic.
        # True when a concurrent session still drives this shared agent. Reaps
        # crash-orphaned presence rows first so a dead process's leftover row
        # can't fool the gate into preserving routing for a sibling that is gone.
        def sibling_sessions_live?(agent)
          AgentSubscription.reap_stale!(agent.id)
          AgentSubscription.live.where(agent_id: agent.id).exists?
        end

        # Scope cancellation to one ending session's topic (used when a live
        # sibling shares the agent, so an agent-wide sweep is unsafe). Tasks on
        # this topic are unambiguously the ending session's — its session topic
        # is private to it.
        def cancel_tasks_for_topic(agent, topic)
          cancel_pending_tasks(Task.where(topic_id: topic.id, status: %w[queued pending running]), agent)
          cancel_delegated_tasks(Task.where(topic_id: topic.id, status: "delegated"), agent)
        end

        def cancel_delegated_tasks_for_session(agent)
          cancel_delegated_tasks(Task.where(agent_id: agent.id, status: "delegated"), agent)
        end

        def cancel_delegated_tasks(tasks, agent)
          return if tasks.empty?

          tracker = Orchestration::ResourceTracker.for(agent)
          tasks.find_each do |task|
            task.update!(status: "cancelled", pending_tool_call: nil)
            tracker.release!(task.id)

            Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          end
        end

        # Cancel pre-delegation tasks for this session's agent:
        #   - queued: waiting in topic queue, no slot reserved
        #   - pending: between dequeue and AiAgentJob#perform, no slot reserved
        #   - running: AiAgentJob is mid-perform; for Claude Channel agents the
        #     slot is reserved with task.id between tracker.reserve! and the
        #     "running → delegated" transition. AiAgentJob#perform reloads the
        #     task before the delegated transition and exits if it sees
        #     "cancelled", so we close that race here.
        #
        # Release the tracker slot defensively for running tasks — release! is
        # idempotent (Set#delete no-ops on missing key) and we don't know from
        # the DB whether AiAgentJob had already reached tracker.reserve!.
        def cancel_pending_tasks_for_session(agent)
          cancel_pending_tasks(Task.where(agent_id: agent.id, status: %w[queued pending running]), agent)
        end

        def cancel_pending_tasks(tasks, agent)
          return if tasks.empty?

          tracker = Orchestration::ResourceTracker.for(agent)
          drained_topics = {}
          tasks.find_each do |task|
            was_running = task.status == "running"
            task.update!(status: "cancelled")
            tracker.release!(task.id) if was_running
            drained_topics[task.topic_id] ||= task.creative_id
          end

          # Drain each affected topic's queue once, AFTER all of this session's
          # pre-dispatch tasks are cancelled. The delegated path dequeues per
          # task, but it never cancels queued tasks; this path does. A per-task
          # dequeue here could promote one of our own still-queued tasks to
          # pending mid-loop, only for the loop to cancel it — and its AiAgentJob
          # early-returns on "cancelled" without dequeuing, re-stranding a live
          # sibling's queued task on the same shared topic. Draining once at the
          # end (when none of our tasks remain queued) promotes the sibling's
          # task instead of ours.
          drained_topics.each do |topic_id, creative_id|
            Orchestration::AgentOrchestrator.dequeue_next_for_topic(topic_id, creative_id)
          end
        end

        def dispatch_a2a(agent, comment, task:)
          AiAgent::A2aDispatcher.new(
            agent: agent,
            reply_comment: comment,
            context: {
              "creative" => { "id" => comment.creative_id },
              "topic" => { "id" => comment.topic_id }
            },
            workspace_user: workspace_user_for(task)
          ).dispatch
        end

        def workspace_user_for(task)
          unless task
            return current_user unless current_user.ai_user?

            return
          end

          payload = task.trigger_event_payload || {}
          user =
            if payload.key?("workspace_user_id")
              User.find_by(id: payload["workspace_user_id"])
            else
              Comment.find_by(id: payload.dig("comment", "id"))&.user
            end

          user unless user&.ai_user?
        end

        # Provisions the (agent, topic) identities for a Claude Code
        # registration. Memoized per request; behavior extracted verbatim.
        def session_provisioner
          @session_provisioner ||= AiAgent::SessionProvisioner.new(current_user)
        end

        # Claims and finalizes delegated tasks on /reply. Stateless, so a single
        # instance is reused for the request.
        def task_claim_service
          @task_claim_service ||= AiAgent::TaskClaimService.new
        end

        # Thin delegator to TaskClaimService#claim. Kept as a controller method
        # (rather than calling the service inline in #reply) so the concurrency
        # test that patches AgentsController#claim_delegated_task to inject a race
        # keeps exercising the same seam.
        def claim_delegated_task(agent, topic, requested_task_id)
          task_claim_service.claim(agent: agent, topic: topic, requested_task_id: requested_task_id)
        end
      end
    end
  end
end

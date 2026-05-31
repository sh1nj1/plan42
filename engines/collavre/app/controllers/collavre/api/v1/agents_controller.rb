# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class AgentsController < BaseController
        # POST /api/v1/agent/register
        # Registers a Claude Code session as an agent:
        # 1. Finds or creates an AI User for this session
        # 2. Creates a Topic in the user's inbox
        # 3. Sets the AI user as primary agent on the topic
        def register
          session_name = params[:name].to_s.strip
          if session_name.blank?
            render json: { error: "name is required" }, status: :unprocessable_entity
            return
          end

          # Per-session ai_user: each MCP session gets its own agent so the
          # per-agent ActionCable stream (agent:user:<id>) and per-agent task
          # scope (Task.where(agent_id: ...)) are isolated. Two concurrent
          # Claude Code sessions for the same human no longer share a stream
          # (which would cause both to receive every dispatch and produce
          # duplicate replies) or share delegated-task scope (which would
          # force unregister to narrow to one topic and leak work-topic tasks).
          ai_user = find_or_create_session_agent(session_name)

          inbox = Creative.inbox_for(current_user)
          topic_name = "Claude #{session_name}"
          topic = inbox.topics.find_or_create_by!(name: topic_name) do |t|
            t.user = current_user
          end
          topic.unarchive! if topic.archived?

          topic.set_primary_agent!(ai_user)

          CreativeShare.find_or_create_by!(creative: inbox, user: ai_user) do |s|
            s.permission = :feedback
            s.shared_by = current_user
          end

          render json: {
            agent_id: ai_user.id,
            agent_name: ai_user.name,
            topic_id: topic.id,
            topic_name: topic.name,
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

          # Fail any tasks still delegated to this MCP session — including
          # dispatches routed to *work* topics outside the registration inbox.
          # The agent is per-session, so agent_id alone uniquely identifies
          # this session's delegated work; scoping by topic_id here would only
          # cancel inbox-topic tasks and leak the actually common case (a /work
          # dispatch on a project topic) until stuck detection times out.
          cancel_delegated_tasks_for_session(ai_user)
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

          comment = creative.comments.build(
            content: params[:text].to_s,
            topic: topic,
            user: agent,
            skip_default_user: true,
            skip_dispatch: true
          )

          if comment.save
            complete_delegated_task(agent, topic, comment, params[:task_id])
            dispatch_a2a(agent, comment)
            render json: { comment_id: comment.id }, status: :created
          else
            render json: { errors: comment.errors.full_messages }, status: :unprocessable_entity
          end
        end
        private

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
        def resolve_reply_agent(topic, requested_task_id)
          if requested_task_id.present?
            task = Task.where(topic_id: topic.id, status: "delegated").find_by(id: requested_task_id)
            agent = task&.agent
            if agent && agent.claude_channel_agent? && agent.created_by_id == current_user.id
              return agent
            end
          end

          agent = topic.primary_agent
          return agent if agent && agent.created_by_id == current_user.id

          nil
        end

        # When Claude responds, complete the delegated task this reply
        # corresponds to so trigger-loop / workflow completion paths fire.
        # Without this, drop-trigger loops stay stuck because
        # Task#trigger_loop_candidate? only triggers on status == "done".
        #
        # Correlation rules:
        #  - If the client echoes back the task_id from the dispatch payload,
        #    complete that specific task (verifying it belongs to the same
        #    agent + topic and is still delegated). This is required when
        #    topic concurrency > 1 — multiple delegated tasks can co-exist
        #    in one topic, and Claude may reply out of dispatch order.
        #  - Otherwise (back-compat for clients that don't yet echo task_id),
        #    fall back to the oldest delegated task in this agent+topic.
        # Also advances the parent workflow (if any) and drains the topic
        # queue, mirroring the completion path AiAgentJob takes for
        # non-delegated runs.
        def complete_delegated_task(agent, topic, comment, requested_task_id)
          scope = Task.where(agent_id: agent.id, topic_id: topic.id, status: "delegated")
          task =
            if requested_task_id.present?
              scope.find_by(id: requested_task_id)
            else
              scope.order(:created_at).first
            end
          return unless task

          Task.transaction do
            comment.update_column(:task_id, task.id)
            task.update!(status: "done")
          end

          # The job that started this task held its ResourceTracker slot under
          # task.id while waiting for the MCP reply; release it now so the
          # agent's concurrency capacity reflects reality.
          Orchestration::ResourceTracker.for(agent).release!(task.id)

          if task.parent_task_id.present?
            Collavre::Comments::WorkflowExecutor.new(task.parent_task).complete_subtask!(task)
          end

          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
        end

        # When an MCP session unregisters, any tasks still in delegated state
        # are abandoned — the client that would have called /reply is gone.
        # Mirror the cancel path so the agent's slot and each topic's queue
        # both free up immediately rather than waiting for stuck detection.
        # Scopes by agent_id only: per-session ai_users mean every delegated
        # task for this agent belongs to this session, on any topic.
        def cancel_delegated_tasks_for_session(agent)
          tasks = Task.where(agent_id: agent.id, status: "delegated")
          return if tasks.empty?

          tracker = Orchestration::ResourceTracker.for(agent)
          tasks.find_each do |task|
            task.update!(status: "cancelled")
            tracker.release!(task.id)

            if task.parent_task_id.present?
              begin
                Collavre::Comments::WorkflowExecutor.new(task.parent_task).fail_subtask!(
                  task, error_message: "Claude Channel session unregistered before reply"
                )
              rescue StandardError => e
                Rails.logger.error(
                  "[AgentsController] fail_subtask! failed for task #{task.id}: #{e.message}"
                )
              end
            end

            Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          end
        end

        def dispatch_a2a(agent, comment)
          AiAgent::A2aDispatcher.new(
            agent: agent,
            reply_comment: comment,
            context: {
              "creative" => { "id" => comment.creative_id },
              "topic" => { "id" => comment.topic_id }
            }
          ).dispatch
        end

        # One ai_user per (current_user, session_name) so each MCP session has
        # its own agent identity. Same session_name re-registering (e.g. the
        # plugin reconnects with the same hostname-pid) reuses the existing
        # row — idempotent retries don't proliferate agents.
        def find_or_create_session_agent(session_name)
          slug = session_name.to_s.downcase.gsub(/[^a-z0-9-]+/, "-").squeeze("-").gsub(/\A-|-\z/, "")
          slug = "session" if slug.blank?
          email = "claude-channel-#{current_user.id}-#{slug}@agent.collavre.local"

          ai_user = User.find_or_initialize_by(email: email)
          if ai_user.new_record?
            ai_user.assign_attributes(
              name: "Claude Channel (#{session_name})",
              password: SecureRandom.hex(32),
              llm_vendor: "anthropic",
              llm_model: "claude-code",
              created_by_id: current_user.id,
              searchable: false,
              routing_expression: "true"
            )
            ai_user.save!
          end

          ai_user
        end
      end
    end
  end
end

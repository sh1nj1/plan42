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

          ai_user = find_or_create_claude_channel_agent

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

          if topic
            # Fail any tasks still delegated to this MCP session before the
            # topic is archived. Without this, the ResourceTracker slot and
            # per-topic queue stay blocked until stuck detection times out.
            cancel_delegated_tasks_for_session(ai_user, topic)
            topic.archive!
          end

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

          agent = topic.primary_agent
          unless agent && agent.created_by_id == current_user.id
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
            complete_delegated_task(agent, topic, comment)
            dispatch_a2a(agent, comment)
            render json: { comment_id: comment.id }, status: :created
          else
            render json: { errors: comment.errors.full_messages }, status: :unprocessable_entity
          end
        end
        private

        # When Claude responds, mark the oldest still-delegated task in this
        # topic as done so trigger-loop / workflow completion paths can fire.
        # Without this, drop-trigger loops stay stuck because
        # Task#trigger_loop_candidate? only triggers on status == "done".
        # Also advance the parent workflow (if any) and drain the topic queue,
        # mirroring the completion path AiAgentJob takes for non-delegated runs.
        def complete_delegated_task(agent, topic, comment)
          task = Task.where(agent_id: agent.id, topic_id: topic.id, status: "delegated")
                     .order(:created_at).first
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
        # Mirror the cancel path so the agent's slot and the topic queue both
        # free up immediately rather than waiting for stuck detection.
        def cancel_delegated_tasks_for_session(agent, topic)
          tasks = Task.where(agent_id: agent.id, topic_id: topic.id, status: "delegated")
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

        def find_or_create_claude_channel_agent
          email = "claude-channel-#{current_user.id}@agent.collavre.local"

          ai_user = User.find_or_initialize_by(email: email)
          if ai_user.new_record?
            ai_user.assign_attributes(
              name: "Claude Channel",
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

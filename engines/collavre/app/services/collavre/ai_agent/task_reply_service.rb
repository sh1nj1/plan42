# frozen_string_literal: true

module Collavre
  module AiAgent
    # Keeps a delegated Claude reply's claim, comment insert, and completion on
    # the topic lock used by TopicMove. A move therefore sees the delegated task
    # and waits, or runs after the complete reply is committed.
    class TaskReplyService
      Result = Data.define(:status, :body, :comment, :agent, :task)

      def initialize(topic:, current_user:, text:, requested_task_id:, agent_resolver:, task_claimer:, claim_service:, pending_approval_ids: [])
        @topic = topic
        @current_user = current_user
        @text = text
        @requested_task_id = requested_task_id
        @agent_resolver = agent_resolver
        @task_claimer = task_claimer
        @claim_service = claim_service
        @pending_approval_ids = pending_approval_ids
      end

      def call
        result = topic.with_lock { build_result }
        Quota::Recovery.succeeded!(result.agent, task: result.task) if result.comment && result.task
        result
      end

      private

      attr_reader :topic, :current_user, :text, :requested_task_id, :agent_resolver, :task_claimer, :claim_service

      def build_result
        creative = topic.creative&.effective_origin
        return result(:not_found, error: "Creative not found") unless creative
        return result(:forbidden, error: "Not authorized") unless creative.has_permission?(current_user, :feedback)

        agent = agent_resolver.call(topic, requested_task_id)
        return result(:forbidden, error: "Not authorized") unless agent

        task = task_claimer.call(agent, topic, requested_task_id)
        return conflict_result(agent) if requested_task_id.present? && task.nil?

        persist_reply(creative, agent, task)
      end

      # `reason` is the machine-readable half of this 409: only
      # "already_completed" means the dispatch was answered and the refused
      # reply is a duplicate. A client that suppresses every conflict as
      # dedup silently drops a valid answer when the task was cancelled,
      # failed, or recovered out of `delegated` mid-turn instead.
      #
      # The duplicate still concludes the caller's turn, so its approvals are
      # handed off exactly as the winner's are. Siblings share the task id, so
      # requests raised by the losing session carry the same origin_task_id;
      # the winner only knew its own, and without this a later decision on the
      # loser's request could never resume the agent.
      def conflict_result(agent)
        error = "Task already completed or not delegated"
        answered = claim_service.answered_task(agent: agent, topic: topic, requested_task_id: requested_task_id)
        return result(:conflict, error: error, reason: TaskClaimService::CONFLICT_NOT_DELEGATED) unless answered

        result(:conflict, error: error, reason: TaskClaimService::CONFLICT_ALREADY_COMPLETED,
                          pending_approval_ids: ClaudeApprovalHandoff.finish!(answered, @pending_approval_ids))
      end

      def persist_reply(creative, agent, task)
        comment = creative.comments.build(
          content: text.to_s, topic: topic, user: agent,
          skip_default_user: true, skip_dispatch: true
        )
        return failed_result(comment, task) unless comment.save

        claim_service.link_reply(task: task, comment: comment) if task
        claim_service.finalize(agent: agent, task: task, comment: comment) if task
        handed_off = task ? ClaudeApprovalHandoff.finish!(task, @pending_approval_ids) : []
        Result.new(status: :created, body: { comment_id: comment.id, pending_approval_ids: handed_off },
                   comment: comment, agent: agent, task: task)
      end

      def failed_result(comment, task)
        claim_service.release(task) if task
        result(:unprocessable_entity, errors: comment.errors.full_messages)
      end

      def result(status, **body)
        Result.new(status: status, body: body, comment: nil, agent: nil, task: nil)
      end
    end
  end
end

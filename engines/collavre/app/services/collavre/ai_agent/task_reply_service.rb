# frozen_string_literal: true

module Collavre
  module AiAgent
    # Keeps a delegated Claude reply's claim, comment insert, and completion on
    # the topic lock used by TopicMove. A move therefore sees the delegated task
    # and waits, or runs after the complete reply is committed.
    class TaskReplyService
      Result = Data.define(:status, :body, :comment, :agent, :task)

      def initialize(topic:, current_user:, text:, requested_task_id:, agent_resolver:, task_claimer:, claim_service:)
        @topic = topic
        @current_user = current_user
        @text = text
        @requested_task_id = requested_task_id
        @agent_resolver = agent_resolver
        @task_claimer = task_claimer
        @claim_service = claim_service
      end

      def call
        result = topic.with_lock { build_result }
        claim_service.finalize(agent: result.agent, task: result.task, comment: result.comment) if result.task
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
        if requested_task_id.present? && task.nil?
          return result(:conflict, error: "Task already completed or not delegated")
        end

        persist_reply(creative, agent, task)
      end

      def persist_reply(creative, agent, task)
        comment = creative.comments.build(
          content: text.to_s, topic: topic, user: agent,
          skip_default_user: true, skip_dispatch: true
        )
        return failed_result(comment, task) unless comment.save

        claim_service.link_reply(task: task, comment: comment) if task
        Result.new(status: :created, body: { comment_id: comment.id }, comment: comment, agent: agent, task: task)
      end

      def failed_result(comment, task)
        task&.update!(status: "delegated")
        result(:unprocessable_entity, errors: comment.errors.full_messages)
      end

      def result(status, **body)
        Result.new(status: status, body: body, comment: nil, agent: nil, task: nil)
      end
    end
  end
end

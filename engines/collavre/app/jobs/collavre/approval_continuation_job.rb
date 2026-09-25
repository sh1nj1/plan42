# frozen_string_literal: true

module Collavre
  # Both external adapters share the durable continuation and topic queue.
  # The comment lock creates at most one new task across repeated deliveries.
  class ApprovalContinuationJob < ApplicationJob
    queue_as :ai_agents

    def perform(comment_id = nil, agent_id = nil)
      scope = Comment.where.not(action: nil)
      scope = comment_id ? scope.where(id: comment_id) : scope.where(user_id: agent_id)
      scope.find_each { |comment| resume(comment) }
    end

    private

    def resume(comment)
      topic = Topic.find_by(id: comment.topic_id)
      return unless topic

      task = topic.with_lock { prepare_task(comment) }
      return unless task

      ActiveRecord.after_all_transactions_commit do
        if task.queued?
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
        elsif task.pending?
          AiAgentJob.perform_later(task)
        end
      end
    end

    def prepare_task(comment)
      comment.with_lock do
        next if comment.private?
        payload = continuation_payload(comment)
        next unless payload
        next unless payload["turn_finished"] && payload["decision"]
        origin = Task.find_by(id: payload["origin_task_id"], agent_id: comment.user_id,
                              topic_id: comment.topic_id, creative_id: comment.creative_id, status: "done")
        next unless origin && eligible_agent?(comment.user)
        next unless comment.creative.has_permission?(comment.user, :feedback)

        existing = Task.find_by(id: payload["resume_task_id"]) if payload["resume_task_id"]
        next existing if payload["resume_task_id"]

        created = create_task(comment, payload, origin)
        comment.update!(action: JSON.generate(JSON.parse(comment.action).merge("resume_task_id" => created.id)))
        created
      end
    end

    def create_task(comment, payload, origin)
      notice = create_notice(comment, payload)
      context = notice.dispatch_payload.deep_stringify_keys
      context["chat"]["mentioned_users"] = [ { "id" => comment.user_id } ]
      context[request_context_key] = payload["request_id"]
      context["workspace_user_id"] = AiAgent::TaskWorkspaceUser.resolve(origin)&.id
      Task.create!(name: event_name.humanize, agent: comment.user,
                   creative: comment.creative, topic_id: comment.topic_id, status: "queued",
                   trigger_event_name: event_name, trigger_event_payload: context)
    end

    def create_notice(comment, payload)
      content = I18n.t("collavre.claude_channel.approval_resume",
                       locale: comment.approver&.locale.presence || I18n.default_locale,
                       request_id: payload["request_id"], question: payload["question"],
                       decision: payload["decision"], reason: payload["reason"].to_s,
                       decided_by: comment.action_executed_by&.display_name)
      comment.creative.comments.create!(
        topic_id: comment.topic_id, user: comment.user, content: content,
        skip_default_user: true, skip_dispatch: true
      )
    end
  end
end

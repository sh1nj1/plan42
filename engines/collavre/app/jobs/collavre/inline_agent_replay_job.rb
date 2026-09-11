# frozen_string_literal: true

module Collavre
  class InlineAgentReplayJob < ApplicationJob
    queue_as :ai_agents

    def perform(comment_id, user_id, task_id = nil)
      comment = Comment.find_by(id: comment_id)
      # The optional fallback accepts jobs queued before task ids were included.
      task = task_id ? Task.find_by(id: task_id) : comment&.task
      return unless task

      user = User.find_by(id: user_id)
      unless comment&.task_id == task.id && user
        CliProxy::InlineLogin.abandon_replay!(task)
        return
      end

      login = CliProxy::InlineLogin.new(comment, user)
      payload = login.replay_payload

      # Carry identity into admission: validation and Task creation must share
      # the source lock, not just run consecutively in this worker.
      AiAgentJob.perform_now(login.agent.id, login.task.trigger_event_name, payload, [ comment.id, user.id, task.id ])
    rescue CliProxy::Client::Error => error
      Rails.logger.info("[InlineAgentReplayJob] Skipping task=#{task.id} code=#{error.code}")
      task = Task.find_by(id: task.id)
      CliProxy::InlineLogin.abandon_replay!(task) if task
    end
  end
end

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
      payload = current_payload(login)
      return unless payload

      # Start inline so another delayed job cannot retain this text snapshot.
      # AiAgentJob still owns topic admission, resource tracking and completion.
      AiAgentJob.perform_now(login.agent.id, login.task.trigger_event_name, payload)
    end

    private

    def current_payload(login)
      login.replay_payload
    rescue CliProxy::Client::Error => error
      Rails.logger.info("[InlineAgentReplayJob] Skipping reply=#{login.comment.id} code=#{error.code}")
      login.abandon_replay!
      nil
    end
  end
end

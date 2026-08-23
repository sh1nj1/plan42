# frozen_string_literal: true

module Collavre
  # CronActionJob is executed by SolidQueue recurring tasks to post
  # a scheduled message into a creative's topic, triggering the
  # agent orchestration pipeline.
  #
  # Created dynamically via the cron_create MCP tool.
  # topic_id can be nil for the main topic.
  class CronActionJob < ApplicationJob
    queue_as :default

    def perform(creative_id:, topic_id:, agent_id:, message:)
      creative = Creative.find_by(id: creative_id)&.effective_origin
      agent = User.find_by(id: agent_id)

      unless creative && agent
        Rails.logger.warn(
          "[CronActionJob] Skipping: creative=#{creative_id} agent=#{agent_id} - record not found"
        )
        return
      end

      topic = topic_id.present? ? Topic.find_by(id: topic_id) : creative.main_topic(fallback_user: agent)
      unless topic
        Rails.logger.warn("[CronActionJob] Skipping: topic=#{topic_id} not found")
        return
      end

      comment = create_comment(creative, topic, agent, message)
      return unless comment

      # Dispatch system event to trigger agent orchestration pipeline
      # (manual because cron-initiated AI messages intentionally need dispatch)
      #
      # The topic comes from the persisted row, not from `topic` above. A cron
      # scheduled against Main passes `topic_id: nil`, but Comment#assign_main_topic
      # files the comment under the creative's real Main topic — so nil describes
      # the *argument*, never where the comment ended up. Everything downstream
      # believes this payload: the task's topic_id, the slot it is admitted into,
      # and the scope AgentOrchestrator.refresh_deferred_context! re-selects an
      # anchor from on promotion. A payload naming a topic its own comment is not
      # in makes all three answer for an empty topic.
      SystemEvents::Dispatcher.dispatch("comment_created", {
        comment: {
          id: comment.id,
          content: comment.content,
          user_id: comment.user_id
        },
        creative: {
          id: creative.id,
          description: creative.description
        },
        topic: {
          id: comment.topic_id
        },
        chat: {
          content: comment.content
        }
      }, source: "cron")

      Rails.logger.info(
        "[CronActionJob] Posted cron message to creative #{creative_id}, topic #{topic_id || 'main'}"
      )
    end

    private

    def create_comment(creative, topic, agent, message)
      comment = nil
      applied = Comments::TopicMutation.call(topic.id, creative.id) do
        comment = creative.comments.create!(
          content: message, user: agent, topic: topic, private: false,
          skip_dispatch: true
        )
      end
      return comment if applied

      Rails.logger.warn(
        "[CronActionJob] Skipping: topic=#{topic.id} no longer belongs to creative=#{creative.id}"
      )
      nil
    end
  end
end

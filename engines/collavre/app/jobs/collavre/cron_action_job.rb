# frozen_string_literal: true

module Collavre
  # CronActionJob is executed by SolidQueue recurring tasks to post
  # a scheduled message into a creative's topic, triggering the
  # agent orchestration pipeline.
  #
  # Created dynamically via the cron_create MCP tool.
  class CronActionJob < ApplicationJob
    queue_as :default

    def perform(creative_id:, topic_id:, agent_id:, message:)
      creative = Creative.find_by(id: creative_id)
      topic = Topic.find_by(id: topic_id)
      agent = User.find_by(id: agent_id)

      unless creative && topic && agent
        Rails.logger.warn(
          "[CronActionJob] Skipping: creative=#{creative_id} topic=#{topic_id} agent=#{agent_id} - record not found"
        )
        return
      end

      comment = creative.comments.create!(
        content: message,
        user: agent,
        topic_id: topic.id,
        private: false
      )

      # Dispatch system event to trigger agent orchestration pipeline
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
          id: topic.id
        },
        chat: {
          content: comment.content
        }
      })

      Rails.logger.info("[CronActionJob] Posted cron message to creative #{creative_id}, topic #{topic_id}")
    end
  end
end

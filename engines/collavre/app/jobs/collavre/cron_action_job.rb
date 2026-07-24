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
      creative = Creative.find_by(id: creative_id)
      agent = User.find_by(id: agent_id)

      unless creative && agent
        Rails.logger.warn(
          "[CronActionJob] Skipping: creative=#{creative_id} agent=#{agent_id} - record not found"
        )
        return
      end

      # topic_id nil means main topic; otherwise look up the topic
      topic = nil
      if topic_id.present?
        topic = Topic.find_by(id: topic_id)
        unless topic
          Rails.logger.warn("[CronActionJob] Skipping: topic=#{topic_id} not found")
          return
        end
      end

      comment = creative.comments.create!(
        content: message,
        user: agent,
        topic_id: topic&.id,
        private: false,
        skip_dispatch: true  # manual dispatch below (AI user would skip model callback)
      )

      # Dispatch system event to trigger agent orchestration pipeline
      # (manual because cron-initiated AI messages intentionally need dispatch)
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
          id: topic&.id
        },
        chat: {
          content: comment.content
        }
      })

      Rails.logger.info(
        "[CronActionJob] Posted cron message to creative #{creative_id}, topic #{topic_id || 'main'}"
      )
    end
  end
end

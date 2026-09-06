# frozen_string_literal: true

module Collavre
  module Crons
    class ChangeBroadcaster
      def self.call(creative)
        origin = creative.effective_origin
        broadcast_topic_change(origin)
        broadcast_tree_change(origin)
      end

      def self.broadcast_topic_change(origin)
        TopicsChannel.broadcast_to(origin, action: "cron_changed")
      rescue StandardError => e
        warn_failure(origin, e)
      end

      def self.broadcast_tree_change(origin)
        CreativeTreeInvalidationJob.perform_later([ origin.id ])
      rescue StandardError => e
        warn_failure(origin, e)
      end

      def self.warn_failure(creative, error)
        Rails.logger.warn("[CronChangeBroadcaster] Broadcast failed for creative #{creative.id}: #{error.message}")
      end

      private_class_method :broadcast_topic_change, :broadcast_tree_change, :warn_failure
    end
  end
end

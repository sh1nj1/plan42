# frozen_string_literal: true

module Collavre
  module Crons
    class ChangeBroadcaster
      def self.call(creative)
        TopicsChannel.broadcast_to(creative.effective_origin, action: "cron_changed")
      rescue StandardError => e
        Rails.logger.warn("[CronChangeBroadcaster] Broadcast failed for creative #{creative.id}: #{e.message}")
      end
    end
  end
end

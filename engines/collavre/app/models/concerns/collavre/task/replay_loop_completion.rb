# frozen_string_literal: true

module Collavre
  class Task
    # A newer active turn temporarily owns completion of an abandoned replay.
    # If it ends without a result, ask the abandoned turn again after commit.
    module ReplayLoopCompletion
      extend ActiveSupport::Concern

      included do
        after_update_commit :recheck_abandoned_replays, if: :saved_change_to_status?
      end

      private

      def recheck_abandoned_replays
        return unless status.in?(%w[failed cancelled escalated]) && trigger_event_name == "comment_created"
        return unless creative&.parent&.drop_trigger_enabled?
        return unless creative.data&.dig("trigger", "loop", "state") == "running"

        Task.where(creative_id: creative_id, topic_id: topic_id, trigger_event_name: "comment_created", status: "done")
            .where("created_at < :time OR (created_at = :time AND id < :id)", time: created_at, id: id)
            .find_each(order: :desc) do |previous|
          next unless previous.trigger_event_payload&.dig("engine_login", "replay_abandoned")

          previous.fire_completion_callbacks_after_external_claim
          break
        end
      end
    end
  end
end

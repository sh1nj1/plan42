# frozen_string_literal: true

module Collavre
  class Comment
    # Withdrawal must stop an admitted turn as well as a pending login card.
    module DispatchRevocation
      extend ActiveSupport::Concern

      included do
        after_update_commit :revoke_source_dispatch, if: :dispatch_revoked?
        after_destroy_commit :cancel_pending_tasks
        after_destroy_commit :abandon_pending_logins
      end

      private

      def dispatch_source_ids(task)
        payload = task.trigger_event_payload || {}
        (Array(payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]) + [ payload.dig("comment", "id") ])
          .compact.map(&:to_i).uniq
      end

      def replay_route_preserved?(task, payload)
        CliProxy::ReplayClaims.ids(payload).empty? || CliProxy::ReplayRouting.permitted?(payload, task.agent)
      end

      def dispatch_revoked?
        saved_change_to_creative_id? || saved_change_to_topic_id? ||
          (saved_change_to_private? && private?) || (saved_change_to_action? && approval_action?)
      end

      def revoke_source_dispatch
        # Reuse deletion's coalesced-anchor recovery and queue/resource cleanup.
        # A hidden waiting notice is not a request to cancel sibling waiters.
        cancel_pending_tasks unless waiting_notice?
        abandon_pending_logins
      end

      def abandon_pending_logins
        # Deletion can precede enqueue, or revocation can cancel an admitted
        # replay. Neither case guarantees another replay job will settle the card.
        Task.where(status: %w[running done])
            .where("id = :task_id OR CAST(trigger_event_payload -> 'comment' ->> 'id' AS TEXT) = :comment_id",
                   task_id: task_id, comment_id: id.to_s).find_each do |candidate|
          CliProxy::InlineLogin.abandon_replay!(candidate, pending: true)
        end
      end
    end
  end
end

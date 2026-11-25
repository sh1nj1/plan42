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

      class_methods do
        # Every comment a task speaks for: its anchor, the siblings it absorbed,
        # and a workflow's fixed anchor.
        def dispatch_source_ids(task)
          payload = task.trigger_event_payload || {}
          (Array(payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]) +
            [ payload.dig("comment", "id"), task.workflow_execution&.context&.dig("comment", "id") ])
            .compact.map(&:to_i).uniq
        end

        # Settle the inline login cards of every withdrawn source in one scan.
        # The payload predicate cannot use an index, so a batch asks it once
        # rather than once per deleted comment.
        def abandon_pending_logins_for(comment_ids:, task_ids:)
          comment_ids = Array(comment_ids).compact.map(&:to_s).uniq
          task_ids = Array(task_ids).compact.uniq
          return if comment_ids.empty? && task_ids.empty?

          Task.where(status: %w[running done])
              .where("id IN (:task_ids) OR CAST(trigger_event_payload -> 'comment' ->> 'id' AS TEXT) IN (:comment_ids)",
                     task_ids: task_ids.presence || [ nil ], comment_ids: comment_ids.presence || [ nil ])
              .find_each do |candidate|
            CliProxy::InlineLogin.abandon_replay!(candidate, pending: true)
          end
        end
      end

      # Prepare withdrawal inside a caller's transaction; queue/session cleanup
      # remains the caller's responsibility after commit.
      def cancel_task_for_withdrawn_source(task)
        return unless dispatch_source_ids(task).include?(id)
        return if reanchor_coalesced_task(task)

        cancel_source_task(task)
      end

      private

      def reanchor_coalesced_task(task)
        return false if task.workflow?
        return false unless %w[queued pending].include?(task.status)

        Task.transaction { reanchor_locked_task(task) }
      rescue ActiveRecord::RecordNotFound
        # The task went away between the scan and the lock (a cascading delete).
        # Nothing to rescue, and nothing left to cancel either.
        false
      end

      def cancel_source_task(task)
        task.workflow? ? Workflow::FixedAnchor.withdraw!(task) : task.cancel_if_active!
      end

      def dispatch_source_ids(task)
        Comment.dispatch_source_ids(task)
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
        if (batch = Comment.current_batch_destruction)
          return batch.defer_login_abandon(self)
        end

        Comment.abandon_pending_logins_for(comment_ids: [ id ], task_ids: [ task_id ])
      end
    end
  end
end

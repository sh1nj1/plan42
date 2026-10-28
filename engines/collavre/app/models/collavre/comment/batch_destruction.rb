# frozen_string_literal: true

module Collavre
  class Comment
    # Destroy many comments as one unit of work.
    #
    # A plain destroy_all runs every comment's destroy in its own transaction,
    # and each one repeats work that is the same for the whole selection: a scan
    # of every active task for the ones this comment speaks for, an unindexed
    # scan of finished tasks for inline login cards, a realtime remove broadcast
    # and a badge recount for the same creative.
    #
    # Here the rows go in one transaction, and while the batch is open the
    # destroy callbacks hand those shared pieces to it instead of doing them
    # themselves: the active tasks are indexed by source once, and the login
    # scan, the removes and the badge recount run once when the batch closes.
    # Every per-comment rule (re-anchoring, approval gates, keep turns, waiting
    # notices) still runs exactly as it does for a single destroy.
    module BatchDestruction
      extend ActiveSupport::Concern

      STATE_KEY = :collavre_comment_batch_destruction

      included do
        # A comment marked deleting_at is already gone for its readers; the
        # BatchDestroyCommentsJob that marked it removes the row.
        scope :not_deleting, -> { where(deleting_at: nil) }
      end

      class Batch
        def initialize
          @removals = Hash.new { |hash, creative| hash[creative] = [] }
          @badge_creatives = {}
          @login_comment_ids = []
          @login_task_ids = []
        end

        # Active task ids per source comment id, built on first use. Cancelling
        # or re-anchoring only ever drops sources from a task, and the batch's
        # own rows are gone before the first callback reads this, so an index
        # taken once never misses a task a later comment would have found.
        def task_ids_for_source(comment_id)
          task_index.fetch(comment_id.to_i, [])
        end

        def defer_removal(comment)
          @removals[comment.creative] << comment
        end

        def defer_badges(creative)
          @badge_creatives[creative.id] ||= creative
        end

        def defer_login_abandon(comment)
          @login_comment_ids << comment.id
          @login_task_ids << comment.task_id
        end

        def flush!
          Comment.abandon_pending_logins_for(comment_ids: @login_comment_ids, task_ids: @login_task_ids)
          @removals.each { |creative, comments| Comment.broadcast_removals(creative, comments) }
          @badge_creatives.each_value { |creative| Comment.broadcast_badges_later(creative) }
        end

        private

        def task_index
          @task_index ||= Task.where(status: Task::ACTIVE_STATUSES).includes(:workflow_execution)
                              .find_each.with_object(Hash.new { |hash, key| hash[key] = [] }) do |task, index|
            Comment.dispatch_source_ids(task).each { |source_id| index[source_id] << task.id }
          end
        end
      end

      class_methods do
        # Hide the selection from every reader now and destroy it in the
        # background: the destroy callbacks scale with the selection.
        def destroy_later(creative, comments)
          ids = comments.map(&:id)
          where(id: ids).update_all(deleting_at: Time.current)
          broadcast_removals(creative, comments)
          BatchDestroyCommentsJob.perform_later(ids)
        end

        # Destroys each comment and returns the ones that were destroyed. Called
        # inside an open batch it simply joins it.
        def destroy_in_batch(comments)
          comments = comments.to_a
          return comments.select(&:destroy) if comments.empty? || current_batch_destruction

          batch = Batch.new
          ActiveSupport::IsolatedExecutionState[STATE_KEY] = batch
          begin
            transaction { comments.select(&:destroy) }
          ensure
            # Only after-commit callbacks feed the batch, so whatever it holds
            # belongs to rows that are already gone — flush it even when a later
            # callback raised.
            ActiveSupport::IsolatedExecutionState[STATE_KEY] = nil
            batch.flush!
          end
        end

        def current_batch_destruction
          ActiveSupport::IsolatedExecutionState[STATE_KEY]
        end
      end

      private

      # Every active task that could speak for this comment. A batch indexes
      # the active tasks once by source and hands each comment only its own;
      # the rows are re-read so each comment sees what the previous one's
      # cancellation or re-anchor left behind.
      def active_tasks_for_withdrawal
        active = Task.where(status: Task::ACTIVE_STATUSES)
        batch = Comment.current_batch_destruction
        return active.find_each unless batch

        active.where(id: batch.task_ids_for_source(id)).order(:id).to_a
      end
    end
  end
end

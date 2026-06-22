# frozen_string_literal: true

# A persisted, locale-independent marker distinguishing a topic-concurrency
# waiting notice (:deferred — queues a topic waiter, so its stop button can
# cancel the blocker) from a :delayed (busy / rate_limited) notice that reuses
# the same "⏳" content but is not waiting on topic capacity. Content is locale
# text and task_id is reserved for Task#reply_comment, so neither can carry this
# signal — hence a dedicated column.
class AddTopicConcurrencyDeferToComments < ActiveRecord::Migration[8.1]
  def up
    add_column :comments, :topic_concurrency_defer, :boolean, default: false, null: false

    # Backfill pre-migration notices. The old gate treated every authorless "⏳"
    # notice as a concurrency notice (prefix-only). Without this, legacy notices
    # default to false and the new marker gates would hide their stop button and
    # stop deleting them from abandoning their queued waiter. Mark only the ones
    # that genuinely have a queued waiter in the same topic/creative — the same
    # condition the runtime gate (topic_blocking_task) checks — so :delayed
    # notices (no queued waiter) correctly stay false.
    execute(<<~SQL.squish)
      UPDATE comments
      SET topic_concurrency_defer = #{quoted_true}
      WHERE user_id IS NULL
        AND topic_id IS NOT NULL
        AND content LIKE '⏳%'
        AND EXISTS (
          SELECT 1 FROM tasks
          WHERE tasks.topic_id = comments.topic_id
            AND tasks.creative_id = comments.creative_id
            AND tasks.status = 'queued'
        )
    SQL
  end

  def down
    remove_column :comments, :topic_concurrency_defer
  end
end

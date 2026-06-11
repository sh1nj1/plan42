# frozen_string_literal: true

# A persisted, locale-independent marker distinguishing a topic-concurrency
# waiting notice (:deferred — queues a topic waiter, so its stop button can
# cancel the blocker) from a :delayed (busy / rate_limited) notice that reuses
# the same "⏳" content but is not waiting on topic capacity. Content is locale
# text and task_id is reserved for Task#reply_comment, so neither can carry this
# signal — hence a dedicated column.
class AddTopicConcurrencyDeferToComments < ActiveRecord::Migration[8.1]
  def change
    add_column :comments, :topic_concurrency_defer, :boolean, default: false, null: false
  end
end

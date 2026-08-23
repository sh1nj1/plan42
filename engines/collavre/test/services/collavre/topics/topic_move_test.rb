# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class TopicMoveTest < ActiveSupport::TestCase
      test "locks the topic before relocating its comments" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        Comment.create!(creative: source, topic: topic, user: user, content: "message",
                        skip_default_user: true, skip_dispatch: true)

        calls = []
        comments = topic.comments
        original_update = comments.method(:update_all)
        lock_topic = -> { calls << :topic_lock }
        move_comments = lambda do |*arguments|
          calls << :comments_update
          original_update.call(*arguments)
        end

        topic.stub(:lock!, lock_topic) do
          topic.stub(:comments, comments) do
            comments.stub(:update_all, move_comments) do
              TopicMove.new(topic: topic, target_creative: destination).call
            end
          end
        end

        assert_equal %i[topic_lock comments_update], calls
      end

      test "rejects a move when the source changes before the lock is acquired" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        intervening = Creative.create!(description: "Intervening", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        comment = Comment.create!(creative: source, topic: topic, user: user, content: "message",
                                  skip_default_user: true, skip_dispatch: true)
        stale_move = TopicMove.new(topic: topic, target_creative: destination)

        TopicMove.new(topic: topic, target_creative: intervening).call

        error = assert_raises(TopicMove::SourceChangedError) do
          stale_move.call
        end

        assert_includes error.message, "moved"
        assert_equal intervening.id, topic.reload.creative_id
        assert_equal intervening.id, comment.reload.creative_id
      end

      test "runs validation after locking and before relocating comments" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        comment = Comment.create!(creative: source, topic: topic, user: user, content: "message",
                                  skip_default_user: true, skip_dispatch: true)

        error = assert_raises(ArgumentError) do
          TopicMove.new(topic: topic, target_creative: destination).call do |locked_topic|
            assert_equal topic, locked_topic
            raise ArgumentError, "rejected"
          end
        end

        assert_equal "rejected", error.message
        assert_equal source.id, topic.reload.creative_id
        assert_equal source.id, comment.reload.creative_id
      end

      test "defers move effects until an enclosing transaction commits" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        effects = []

        ApplicationRecord.transaction do
          TopicMove.new(topic: topic, target_creative: destination).call(
            after_commit: ->(current_topic) { effects << current_topic.creative_id }
          )

          assert_empty effects
        end

        assert_equal [ destination.id ], effects
      end

      test "discards move effects when an enclosing transaction rolls back" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        effects = []

        ApplicationRecord.transaction do
          TopicMove.new(topic: topic, target_creative: destination).call(
            after_commit: ->(current_topic) { effects << current_topic.creative_id }
          )
          raise ActiveRecord::Rollback
        end

        assert_empty effects
        assert_equal source.id, topic.reload.creative_id
      end

      test "runs source cleanup when the moved topic is deleted before post-commit effects" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        effect_topics = []
        run_after_commit = lambda do |&callback|
          topic.destroy!
          callback.call
        end

        ActiveRecord.stub(:after_all_transactions_commit, run_after_commit) do
          TopicMove.new(topic: topic, target_creative: destination).call(
            after_commit: ->(current_topic) { effect_topics << current_topic }
          )
        end

        assert_equal [ nil ], effect_topics
      end

      test "moves comment snapshots with the topic" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        snapshot = CommentSnapshot.create!(
          creative: source, topic: topic, user: user, operation: "compress",
          comments_data: [
            { "id" => 1, "user_id" => user.id, "topic_id" => topic.id, "content" => "original" }
          ]
        )

        TopicMove.new(topic: topic, target_creative: destination).call
        restored = CommentSnapshotRestoreService.new(snapshot: snapshot, user: user).call

        assert_equal destination.id, snapshot.reload.creative_id
        assert_equal topic.id, snapshot.topic_id
        assert_equal destination.id, restored.first.creative_id
        assert_equal topic.id, restored.first.topic_id
      end

      test "clears source last-topic preferences and advances their revisions" do
        user = users(:one)
        other_user = users(:two)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        preference = UserCreativePreference.create!(
          creative: source, user: other_user, expanded_status: {},
          last_topic: topic, last_topic_revision: 4
        )

        TopicMove.new(topic: topic, target_creative: destination).call

        preference.reload
        assert_nil preference.last_topic_id
        assert_equal 5, preference.last_topic_revision
      end

      test "restores source last-topic preferences when the move rolls back" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        preference = UserCreativePreference.create!(
          creative: source, user: users(:two), expanded_status: {},
          last_topic: topic, last_topic_revision: 4
        )

        ApplicationRecord.transaction do
          TopicMove.new(topic: topic, target_creative: destination).call
          raise ActiveRecord::Rollback
        end

        preference.reload
        assert_equal topic.id, preference.last_topic_id
        assert_equal 4, preference.last_topic_revision
      end

      test "snapshot restoration locks the topic before the snapshot" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        topic = source.topics.create!(name: "Restore", user: user)
        snapshot = CommentSnapshot.create!(
          creative: source, topic: topic, user: user, operation: "compress",
          comments_data: [ { "id" => 1, "user_id" => user.id, "topic_id" => topic.id, "content" => "original" } ]
        )
        calls = []
        topic_scope = Topic.lock
        snapshot_scope = CommentSnapshot.lock

        Topic.stub(:lock, -> { calls << :topic; topic_scope }) do
          CommentSnapshot.stub(:lock, -> { calls << :snapshot; snapshot_scope }) do
            CommentSnapshotRestoreService.new(snapshot: snapshot, user: user).call
          end
        end

        assert_equal %i[topic snapshot], calls.first(2)
      end

      test "rejects every active task status before relocating topic data" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)

        Task::ACTIVE_STATUSES.each do |status|
          topic = source.topics.create!(name: "Moving #{status}", user: user)
          comment = Comment.create!(creative: source, topic: topic, user: user, content: "message",
                                    skip_default_user: true, skip_dispatch: true)
          snapshot = CommentSnapshot.create!(
            creative: source, topic: topic, user: user, operation: "compress",
            comments_data: [ { "id" => comment.id, "topic_id" => topic.id, "content" => "message" } ]
          )
          Task.create!(name: status, agent: user, creative: source, topic_id: topic.id, status: status)

          error = assert_raises(TopicMove::ActiveTaskError) do
            TopicMove.new(topic: topic, target_creative: destination).call
          end

          assert_equal I18n.t("collavre.topics.move.active_tasks"), error.message
          assert_equal source.id, topic.reload.creative_id
          assert_equal source.id, comment.reload.creative_id
          assert_equal source.id, snapshot.reload.creative_id
        end
      end

      test "allows a topic with only terminal tasks to move" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)

        %w[done failed cancelled escalated].each do |status|
          Task.create!(name: status, agent: user, creative: source, topic_id: topic.id, status: status)
        end

        TopicMove.new(topic: topic, target_creative: destination).call

        assert_equal destination.id, topic.reload.creative_id
      end

      test "rejects a terminal task that still owes a dropped dispatch" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        dropped = Comment.create!(creative: source, topic: topic, user: users(:two), content: "Dropped",
                                  skip_default_user: true, skip_dispatch: true)
        Task.create!(
          name: "Cancelled turn", agent: user, creative: source, topic_id: topic.id, status: "cancelled",
          trigger_event_payload: {
            "topic" => { "id" => topic.id }, "creative" => { "id" => source.id },
            Orchestration::DeliveryRecord::DROPPED_KEY => [ dropped.id ],
            Orchestration::DeliveryRecord::RESTORED_KEY => [ dropped.id ]
          }
        )

        error = assert_raises(TopicMove::PendingDeliveryError) do
          TopicMove.new(topic: topic, target_creative: destination).call
        end

        assert_equal I18n.t("collavre.topics.move.pending_deliveries"), error.message
        assert_equal source.id, topic.reload.creative_id
      end

      test "allows a terminal task whose dropped dispatch reached the provider" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        dropped = Comment.create!(creative: source, topic: topic, user: users(:two), content: "Delivered",
                                  skip_default_user: true, skip_dispatch: true)
        Task.create!(
          name: "Completed turn", agent: user, creative: source, topic_id: topic.id, status: "done",
          trigger_event_payload: {
            "topic" => { "id" => topic.id }, "creative" => { "id" => source.id },
            Orchestration::DeliveryRecord::DROPPED_KEY => [ dropped.id ],
            Orchestration::DeliveryRecord::HANDED_OFF_KEY => true,
            Orchestration::DeliveryRecord::HANDED_OFF_IDS_KEY => [ dropped.id ]
          }
        )

        TopicMove.new(topic: topic, target_creative: destination).call

        assert_equal destination.id, topic.reload.creative_id
      end

      test "allows a terminal task whose dropped comments are no longer restorable" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Moving", user: user)
        create_comment = lambda do |**attributes|
          Comment.create!(creative: source, topic: topic, content: "Dropped",
                          skip_default_user: true, skip_dispatch: true, **attributes)
        end
        deleted = create_comment.call(user: users(:two)).tap(&:destroy!)
        private_comment = create_comment.call(user: users(:two), private: true)
        approval = create_comment.call(user: users(:two), action: "approve")
        agent_comment = create_comment.call(user: user)
        system_comment = create_comment.call(user: nil)
        dropped_ids = [ deleted, private_comment, approval, agent_comment, system_comment ].map(&:id)
        Task.create!(
          name: "Cancelled turn", agent: user, creative: source, topic_id: topic.id, status: "cancelled",
          trigger_event_payload: {
            "topic" => { "id" => topic.id }, "creative" => { "id" => source.id },
            Orchestration::DeliveryRecord::DROPPED_KEY => dropped_ids
          }
        )

        TopicMove.new(topic: topic, target_creative: destination).call

        assert_equal destination.id, topic.reload.creative_id
      end

      test "rejects a topic targeted by a recurring cron job" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Recurring", user: user)
        task = SolidQueue::RecurringTask.create!(
          key: "cron_#{source.id}_#{SecureRandom.hex(4)}",
          class_name: "Collavre::CronActionJob", schedule: "0 9 * * *",
          queue_name: "default", static: false,
          arguments: [ { creative_id: source.id, topic_id: topic.id,
                         agent_id: user.id, message: "Daily" } ]
        )

        error = assert_raises(TopicMove::RecurringTaskError) do
          TopicMove.new(topic: topic, target_creative: destination).call
        end

        assert_equal I18n.t("collavre.topics.move.recurring_tasks"), error.message
        assert_equal source.id, topic.reload.creative_id
      ensure
        task&.destroy
      end

      test "rejects a topic referenced by a trigger loop in every resumable state" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)

        %w[idle running pending_verification paused awaiting_user stuck completed max_reached].each do |state|
          topic = source.topics.create!(name: "Trigger #{state}", user: user)
          source.update!(data: {
            "trigger" => { "loop" => { "state" => state, "trigger_topic_id" => topic.id } }
          })

          error = assert_raises(TopicMove::TriggerLoopError) do
            TopicMove.new(topic: topic, target_creative: destination).call
          end

          assert_equal I18n.t("collavre.topics.move.trigger_loop"), error.message
          assert_equal source.id, topic.reload.creative_id
        end
      end

      test "allows a topic not referenced by the creative trigger loop to move" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        trigger_topic = source.topics.create!(name: "Trigger", user: user)
        moving_topic = source.topics.create!(name: "Moving", user: user)
        source.update!(data: {
          "trigger" => { "loop" => { "state" => "running", "trigger_topic_id" => trigger_topic.id } }
        })

        TopicMove.new(topic: moving_topic, target_creative: destination).call

        assert_equal destination.id, moving_topic.reload.creative_id
      end

      test "reads trigger loop configuration after acquiring the topic lock" do
        user = users(:one)
        source = Creative.create!(description: "Source", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Trigger", user: user)
        topic.creative
        Creative.find(source.id).update!(data: {
          "trigger" => { "loop" => { "state" => "running", "trigger_topic_id" => topic.id } }
        })

        assert_raises(TopicMove::TriggerLoopError) do
          TopicMove.new(topic: topic, target_creative: destination).call
        end

        assert_equal source.id, topic.reload.creative_id
      end

      test "active task error is translated in English and Korean" do
        %w[active_tasks recurring_tasks trigger_loop].each do |key|
          assert I18n.exists?("collavre.topics.move.#{key}", :en)
          assert I18n.exists?("collavre.topics.move.#{key}", :ko)
        end
      end
    end
  end
end

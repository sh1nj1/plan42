require "test_helper"

module Collavre
  module Comments
    # Monotonicity used to come from a row lock around a read/modify/write. It
    # now comes from the write itself, so these cover the case the lock existed
    # for: a request whose view of the pointer is already stale by the time it
    # writes.
    class ReadPointerWriterTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = Creative.create!(description: "Writer", user: @user)
        @topic = @creative.topics.create!(name: "Topic", user: @user)
        @comments = Array.new(3) { Comment.create!(creative: @creative, topic: @topic, user: users(:two), content: "c") }
      end

      test "creates a pointer at the requested watermark" do
        writer.call(@topic.id => @comments.last.id)

        assert_equal @comments.last.id, pointer_watermark(@topic.id)
      end

      test "materialises a pointer even with nothing read yet" do
        empty_topic = @creative.topics.create!(name: "Empty", user: @user)
        writer.call(empty_topic.id => nil)

        assert CommentReadPointer.exists?(user: @user, creative: @creative, topic: empty_topic)
        assert_nil pointer_watermark(empty_topic.id)
      end

      test "an older watermark never moves a named pointer backwards" do
        writer.call(@topic.id => @comments.last.id)
        writer.call(@topic.id => @comments.first.id)

        assert_equal @comments.last.id, pointer_watermark(@topic.id)
      end

      test "a concurrent advance survives a stale named write" do
        writer.call(@topic.id => @comments.first.id)
        positions = nil

        racing_writer = writer
        with_stale_first_read(racing_writer, @topic.id => @comments.first.id) do
          # Another tab advances the row after this request read it.
          CommentReadPointer.where(user: @user, creative: @creative, topic: @topic)
                            .update_all(last_read_comment_id: @comments.last.id)
          positions = racing_writer.call(@topic.id => @comments[1].id)
        end

        assert_equal @comments.last.id, pointer_watermark(@topic.id),
          "the database, not the request's stale read, decides the watermark"
        assert_equal @comments.last.id, positions.last.last,
          "the receipt is repainted at the retained watermark, not this request's stale one"
        assert_not_includes positions.map(&:last), @comments[1].id
      end

      test "a concurrent advance survives a stale legacy write" do
        legacy_comments = Array.new(3) { Comment.create!(creative: @creative, user: users(:two), content: "legacy") }
        writer.call(nil => legacy_comments.first.id)
        positions = nil

        racing_writer = writer
        with_stale_first_read(racing_writer, nil => legacy_comments.first.id) do
          CommentReadPointer.where(user: @user, creative: @creative, topic: nil)
                            .update_all(last_read_comment_id: legacy_comments.last.id)
          positions = racing_writer.call(nil => legacy_comments[1].id)
        end

        assert_equal legacy_comments.last.id, pointer_watermark(nil)
        assert_equal legacy_comments.last.id, positions.last.last
      end

      test "a first-time legacy write survives another request creating the row first" do
        legacy_comment = Comment.create!(creative: @creative, user: users(:two), content: "legacy")

        racing_writer = writer
        with_stale_first_read(racing_writer, {}) do
          # Both requests saw no legacy pointer; the other one inserts first.
          CommentReadPointer.create!(user: @user, creative: @creative, topic: nil, last_read_comment_id: legacy_comment.id)
          assert_nothing_raised { racing_writer.call(nil => legacy_comment.id) }
        end

        assert_equal legacy_comment.id, pointer_watermark(nil)
        assert_equal 1, CommentReadPointer.where(user: @user, creative: @creative, topic: nil).count
      end

      test "reports the superseded and current positions to repaint" do
        writer.call(@topic.id => @comments.first.id)
        positions = writer.call(@topic.id => @comments.last.id)

        assert_equal [ [ @topic.id, @comments.first.id ], [ @topic.id, @comments.last.id ] ], positions
      end

      test "reports nothing when there is nothing to mark read" do
        assert_empty writer.call({})
      end

      test "rejects a named pointer after its topic moves to another creative" do
        destination = Creative.create!(description: "Destination", user: @user)
        stale_writer = writer
        Topics::TopicMove.new(topic: @topic, target_creative: destination).call

        assert_raises(ReadPointerWriter::StaleTopicError) do
          stale_writer.call(@topic.id => @comments.last.id)
        end

        assert_nil CommentReadPointer.find_by(user: @user, creative: @creative, topic: @topic)
      end

      test "locks the creative before snapshotting archived topic fallbacks" do
        archived = @creative.topics.create!(name: "Archived fallback", user: @user, archived_at: Time.current)
        topics = @creative.topics
        original_ids = topics.method(:ids)
        creative_locked = false
        ids_after_lock = lambda do
          assert creative_locked
          original_ids.call
        end

        @creative.stub(:lock!, -> { creative_locked = true; @creative }) do
          @creative.stub(:topics, topics) do
            topics.stub(:ids, ids_after_lock) do
              writer.call(nil => @comments.last.id)
            end
          end
        end

        assert CommentReadPointer.exists?(user: @user, creative: @creative, topic: archived)
      end

      test "snapshots an incoming topic after locking the destination creative" do
        source = Creative.create!(description: "Incoming source", user: @user)
        incoming = source.topics.create!(name: "Incoming", user: @user)
        Comment.create!(creative: source, topic: incoming, user: users(:two), content: "unread incoming")
        legacy = Comment.create!(creative: @creative, user: users(:two), content: "destination legacy")
        move_before_lock = lambda do
          Topics::TopicMove.new(topic: incoming, target_creative: @creative).call
          @creative
        end

        @creative.stub(:lock!, move_before_lock) do
          writer.call(nil => legacy.id)
        end

        pointer = CommentReadPointer.find_by!(user: @user, creative: @creative, topic: incoming)
        assert_nil pointer.last_read_comment_id
      end

      private

      # Only the read that precedes the write is stale; the writer's read-back
      # has to see the real post-write row, which is the whole point of it.
      def with_stale_first_read(target, stale, &block)
        reads = 0
        target.stub(:existing_watermarks, lambda {
          reads += 1
          reads == 1 ? stale : CommentReadPointer.where(user: @user, creative: @creative).pluck(:topic_id, :last_read_comment_id).to_h
        }, &block)
      end

      def writer
        ReadPointerWriter.new(creative: @creative, user: @user)
      end

      def pointer_watermark(topic_id)
        CommentReadPointer.find_by(user: @user, creative: @creative, topic_id: topic_id)&.last_read_comment_id
      end
    end
  end
end

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

        racing_writer = writer
        racing_writer.stub(:existing_watermarks, { @topic.id => @comments.first.id }) do
          # Another tab advances the row after this request read it.
          CommentReadPointer.where(user: @user, creative: @creative, topic: @topic)
                            .update_all(last_read_comment_id: @comments.last.id)
          racing_writer.call(@topic.id => @comments[1].id)
        end

        assert_equal @comments.last.id, pointer_watermark(@topic.id),
          "the database, not the request's stale read, decides the watermark"
      end

      test "a concurrent advance survives a stale legacy write" do
        legacy_comments = Array.new(3) { Comment.create!(creative: @creative, user: users(:two), content: "legacy") }
        writer.call(nil => legacy_comments.first.id)

        racing_writer = writer
        racing_writer.stub(:existing_watermarks, { nil => legacy_comments.first.id }) do
          CommentReadPointer.where(user: @user, creative: @creative, topic: nil)
                            .update_all(last_read_comment_id: legacy_comments.last.id)
          racing_writer.call(nil => legacy_comments[1].id)
        end

        assert_equal legacy_comments.last.id, pointer_watermark(nil)
      end

      test "reports the superseded and current positions to repaint" do
        writer.call(@topic.id => @comments.first.id)
        positions = writer.call(@topic.id => @comments.last.id)

        assert_equal [ [ @topic.id, @comments.first.id ], [ @topic.id, @comments.last.id ] ], positions
      end

      test "reports nothing when there is nothing to mark read" do
        assert_empty writer.call({})
      end

      private

      def writer
        ReadPointerWriter.new(creative: @creative, user: @user)
      end

      def pointer_watermark(topic_id)
        CommentReadPointer.find_by(user: @user, creative: @creative, topic_id: topic_id)&.last_read_comment_id
      end
    end
  end
end

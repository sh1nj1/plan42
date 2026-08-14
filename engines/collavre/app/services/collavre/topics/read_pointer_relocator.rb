# frozen_string_literal: true

module Collavre
  module Topics
    # Topic cursors follow their topic across creatives, even while a reader is
    # temporarily unable to access its new location. Receipt rendering filters
    # inaccessible readers, while retaining the cursor prevents a deleted source
    # creative from losing that reader's history.
    class ReadPointerRelocator
      def initialize(topic:, target_creative:)
        @topic = topic
        @target_creative = target_creative
      end

      def call
        relocate_existing_pointers
        initialize_destination_pointers
      end

      private

      attr_reader :topic, :target_creative

      def relocate_existing_pointers
        CommentReadPointer.where(topic: topic).where.not(creative: target_creative).find_each do |pointer|
          relocate_pointer(pointer)
        end
      end

      def relocate_pointer(pointer)
        destination = CommentReadPointer.find_by(user: pointer.user, creative: target_creative, topic: topic)
        return pointer.update_column(:creative_id, target_creative.id) unless destination

        destination.update_column(:last_read_comment_id, newest_read_id(destination, pointer))
        pointer.delete
      end

      def newest_read_id(destination, pointer)
        [ destination.last_read_comment_id, pointer.last_read_comment_id ].compact.max
      end

      # Existing destination cursors are the only readers that need a topic row:
      # otherwise their unrelated legacy cursor becomes the moved topic fallback.
      def initialize_destination_pointers
        readable_user_ids = CreativeShare.readable_user_ids_from_shares(target_creative, destination_reader_ids)
        rows = (readable_user_ids - destination_topic_reader_ids).map { |user_id| new_pointer_row(user_id) }
        CommentReadPointer.insert_all(rows, unique_by: :index_comment_read_pointers_on_user_creative_and_topic) if rows.any?
      end

      def destination_reader_ids
        CommentReadPointer.where(creative: target_creative).distinct.pluck(:user_id)
      end

      def destination_topic_reader_ids
        CommentReadPointer.where(creative: target_creative, topic: topic).pluck(:user_id)
      end

      def new_pointer_row(user_id)
        now = Time.current
        {
          user_id: user_id, creative_id: target_creative.id, topic_id: topic.id,
          last_read_comment_id: nil, created_at: now, updated_at: now
        }
      end
    end
  end
end

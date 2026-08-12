module Collavre
  class CommentReadPointersController < ApplicationController
    def update
      creative = Creative.find(params[:creative_id]).effective_origin
      topic = params[:topic_id].present? && creative.topics.find_by(id: params[:topic_id])
      return head :unprocessable_entity if params[:topic_id].present? && !topic

      if topic
        update_topic_pointer(creative, topic)
      else
        update_all_topic_pointers(creative)
      end

      Comment.broadcast_badge(creative, Current.user)

      render json: { success: true }
    end

    private

    def update_topic_pointer(creative, topic)
      last_id = creative.comments.visible_to(Current.user).where(topic: topic).maximum(:id)
      update_pointer(creative, topic, last_id)
    end

    # All Messages renders Main plus active topics, not archived ones. Do not
    # advance the retained legacy pointer here: an archived topic without its
    # own pointer falls back to it, so moving that watermark would silently mark
    # its hidden comments as read.
    def update_all_topic_pointers(creative)
      visible_comments = creative.comments.visible_to(Current.user)
      creative.topics.active.find_each do |topic|
        update_pointer(creative, topic, visible_comments.where(topic: topic).maximum(:id))
      end
    end

    def update_pointer(creative, topic, last_id)
      pointer = CommentReadPointer.find_or_initialize_by(user: Current.user, creative: creative, topic: topic)
      previous_last_read_id = pointer.last_read_comment_id
      pointer.update!(last_read_comment_id: last_id)

      broadcast_read_receipts(creative, previous_last_read_id, topic: topic) if previous_last_read_id && previous_last_read_id != last_id
      broadcast_read_receipts(creative, last_id, topic: topic)
    end

    def broadcast_read_receipts(creative, comment_id, topic:)
      return unless comment_id

      # We map to the nearest PUBLIC comment to avoid leaking the existence/ID of private comments
      # via the public action cable channel.
      # Trade-off: Private-only threads (with no preceding public comment) will not get real-time read updates.
      effective_id = find_nearest_public_comment_id(creative, comment_id, topic: topic)
      return unless effective_id

      users = fetch_users_on_effective_id(creative, effective_id, topic: topic)

      present_user_ids = CommentPresenceStore.list(creative.id)

      Turbo::StreamsChannel.broadcast_update_to(
        [ creative, :comments ],
        target: "read_receipts_comment_#{effective_id}",
        partial: "collavre/comments/read_receipts",
        locals: { read_by_users: users, present_user_ids: present_user_ids }
      )
    end

    def find_nearest_public_comment_id(creative, comment_id, topic:)
      creative.comments.public_only.where(topic: topic).where("id <= ?", comment_id).maximum(:id)
    end

    def fetch_users_on_effective_id(creative, effective_id, topic:)
      public_comments = creative.comments.public_only.where(topic: topic)
      next_public_id = public_comments.where("id > ?", effective_id).minimum(:id)

      query = CommentReadPointer.where(creative: creative, topic: topic)
                                .where("last_read_comment_id >= ?", effective_id)

      query = query.where("last_read_comment_id < ?", next_public_id) if next_public_id

      query.includes(user: { avatar_attachment: :blob }).map(&:user)
    end
  end
end

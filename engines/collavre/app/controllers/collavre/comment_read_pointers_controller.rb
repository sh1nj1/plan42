module Collavre
  class CommentReadPointersController < ApplicationController
    LEGACY_TOPIC_WATERMARK_KEY = "_legacy"
    def update
      creative = Creative.find(params[:creative_id]).effective_origin
      topic = params[:topic_id].present? && creative.topics.find_by(id: params[:topic_id])
      return head :unprocessable_entity if params[:topic_id].present? && !topic

      if topic
        update_topic_pointer(creative, topic)
      else
        update_all_topic_pointers(
          creative,
          params[:topic_ids],
          params[:topic_watermarks],
          rendered_topic_ids_supplied: params.key?(:topic_ids)
        )
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
    def update_all_topic_pointers(creative, rendered_topic_ids, rendered_topic_watermarks, rendered_topic_ids_supplied: false)
      visible_comments = creative.comments.visible_to(Current.user)
      raw_topic_watermarks = rendered_topic_watermarks.respond_to?(:to_unsafe_h) ? rendered_topic_watermarks.to_unsafe_h : rendered_topic_watermarks.to_h
      legacy_watermark = raw_topic_watermarks[LEGACY_TOPIC_WATERMARK_KEY].to_i
      topic_watermarks = raw_topic_watermarks.filter_map do |topic_id, comment_id|
        [ topic_id.to_i, comment_id.to_i ] if topic_id.to_i.positive? && comment_id.to_i.positive?
      end.to_h

      if topic_watermarks.any?
        creative.topics.where(id: topic_watermarks.keys).find_each do |topic|
          last_id = visible_comments.where(topic: topic).where("comments.id <= ?", topic_watermarks.fetch(topic.id)).maximum(:id)
          update_pointer(creative, topic, last_id)
        end
      end

      update_legacy_pointer(creative, visible_comments, legacy_watermark) if legacy_watermark.positive?
      return if topic_watermarks.any? || legacy_watermark.positive?

      # Current clients send the rendered-topic snapshot that produced the open
      # All Messages list. An explicitly empty snapshot is authoritative; keep
      # the creative-wide fallback only for clients deployed before this API.
      return update_legacy_client_pointers(creative, visible_comments) unless rendered_topic_ids_supplied

      topics = creative.topics.where(id: Array(rendered_topic_ids))

      topics.find_each do |topic|
        update_pointer(creative, topic, visible_comments.where(topic: topic).maximum(:id))
      end
    end

    # Clients deployed before topic-scoped watermarks only send creative_id.
    # Preserve the previous creative-wide endpoint semantics for them: every
    # named topic, including archived topics, and the retained legacy lane
    # advance through the visible history.
    def update_legacy_client_pointers(creative, visible_comments)
      creative.topics.find_each do |topic|
        update_pointer(creative, topic, visible_comments.where(topic: topic).maximum(:id))
      end

      legacy_last_id = visible_comments.where(topic_id: nil).maximum(:id)
      update_legacy_pointer(creative, visible_comments, legacy_last_id) if legacy_last_id
    end

    def update_pointer(creative, topic, last_id)
      # A named pointer replaces the legacy fallback for this topic. Remember
      # the fallback before creating the row so its previously rendered receipt
      # is replaced as well, rather than lingering until the next page load.
      legacy_last_read_id = CommentReadPointer.find_by(user: Current.user, creative: creative, topic: nil)&.last_read_comment_id
      pointer = CommentReadPointer.find_or_create_by!(user: Current.user, creative: creative, topic: topic)
      created_pointer = pointer.previously_new_record?
      previous_last_read_id = nil
      updated_last_read_id = nil

      # A delayed All Messages update may contain an older rendered watermark
      # than one already saved by another tab. Locking the row makes the
      # read/maximum/write sequence forward-only under concurrent requests.
      pointer.with_lock do
        previous_last_read_id = pointer.last_read_comment_id
        updated_last_read_id = [ previous_last_read_id, last_id ].compact.max
        pointer.update!(last_read_comment_id: updated_last_read_id) if previous_last_read_id != updated_last_read_id
      end

      broadcast_read_receipts(creative, legacy_last_read_id, topic: topic) if created_pointer && legacy_last_read_id
      broadcast_read_receipts(creative, previous_last_read_id, topic: topic) if previous_last_read_id && previous_last_read_id != updated_last_read_id
      broadcast_read_receipts(creative, updated_last_read_id, topic: topic)
    end

    def update_legacy_pointer(creative, visible_comments, watermark)
      last_id = visible_comments.where(topic_id: nil).where("comments.id <= ?", watermark).maximum(:id)
      return unless last_id

      pointer = CommentReadPointer.find_or_create_by!(user: Current.user, creative: creative, topic: nil)
      previous_last_read_id = nil
      updated_last_read_id = nil

      pointer.with_lock do
        previous_last_read_id = pointer.last_read_comment_id
        updated_last_read_id = [ previous_last_read_id, last_id ].compact.max

        if previous_last_read_id != updated_last_read_id
          preserve_named_topic_fallbacks(creative, previous_last_read_id)
          pointer.update!(last_read_comment_id: updated_last_read_id)
        end
      end

      broadcast_read_receipts(creative, previous_last_read_id, topic: nil) if previous_last_read_id && previous_last_read_id != updated_last_read_id
      broadcast_read_receipts(creative, updated_last_read_id, topic: nil)
    end

    # A legacy pointer is also the fallback watermark for named topics that do
    # not yet have their own pointer. Before moving it forward for a rendered
    # topic-less comment, make that prior fallback explicit for every named
    # topic. A nil named pointer deliberately represents the initial (zero)
    # watermark and prevents an unseen older topic from inheriting the new
    # legacy value.
    def preserve_named_topic_fallbacks(creative, previous_last_read_id)
      existing_topic_ids = CommentReadPointer.where(user: Current.user, creative: creative).where.not(topic_id: nil).select(:topic_id)
      now = Time.current
      rows = creative.topics.where.not(id: existing_topic_ids).pluck(:id).map do |topic_id|
        {
          user_id: Current.user.id,
          creative_id: creative.id,
          topic_id: topic_id,
          last_read_comment_id: previous_last_read_id,
          created_at: now,
          updated_at: now
        }
      end

      CommentReadPointer.insert_all(rows, unique_by: :index_comment_read_pointers_on_user_creative_and_topic) if rows.any?
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

      query = CommentReadPointer.where(creative: creative)
                                .where("last_read_comment_id >= ?", effective_id)

      query = query.where("last_read_comment_id < ?", next_public_id) if next_public_id

      pointers = receipt_pointers_for_topic(query, creative, topic).includes(user: { avatar_attachment: :blob }).to_a
      readable_user_ids = CreativeShare.readable_user_ids_from_shares(creative, pointers.map(&:user_id)).to_set

      pointers.select { |pointer| readable_user_ids.include?(pointer.user_id) }.map(&:user)
    end

    # The retained legacy pointer is authoritative for a named topic until the
    # user has a pointer for that topic. Keep the live Turbo update aligned with
    # ReadReceiptIndex so it does not remove a valid fallback receipt.
    def receipt_pointers_for_topic(query, creative, topic)
      return query.where(topic: nil) unless topic

      named_pointers = query.where(topic: topic)
      named_pointer_user_ids = CommentReadPointer.where(creative: creative, topic: topic).select(:user_id)
      legacy_pointers = query.where(topic: nil).where.not(user_id: named_pointer_user_ids)

      named_pointers.or(legacy_pointers)
    end
  end
end

# frozen_string_literal: true

module Collavre
  module Comments
    # Repaints read-receipt avatars for a batch of watermark positions.
    #
    # A receipt is drawn on the nearest PUBLIC comment at or before a pointer, so
    # the public channel never reveals the existence or id of a private comment.
    # Trade-off, unchanged: a private-only thread with no preceding public
    # comment gets no live receipt update.
    #
    # Resolving that mapping used to cost five queries per position, which made
    # marking All Messages read scale with the number of rendered topics. The
    # work is the same, but every step is now issued once for the whole batch.
    class ReadReceiptBroadcaster
      Target = Struct.new(:topic_id, :comment_id, :next_comment_id, keyword_init: true)

      def initialize(creative:)
        @creative = creative
      end

      # positions: [topic_id, comment_id] pairs, in the order they should paint.
      def call(positions)
        targets = resolve_targets(positions)
        return if targets.empty?

        readers = readers_by_comment_id(targets)
        present_user_ids = CommentPresenceStore.list(creative.id)
        targets.each do |target|
          broadcast(target.comment_id, readers.fetch(target.comment_id, []), present_user_ids)
        end
      end

      private

      attr_reader :creative

      def comment_table
        Comment.arel_table
      end

      def pointer_table
        CommentReadPointer.arel_table
      end

      # A grouped aggregate answers one topic per query, so positions are split
      # into rounds that each mention a topic at most once. Callers pass at most
      # a superseded and a current position per topic, which keeps this at two
      # rounds however many topics were marked read.
      def rounds(pairs)
        remaining = pairs
        [].tap do |result|
          until remaining.empty?
            seen = Set.new
            round, remaining = remaining.partition { |topic_id, _| seen.add?(topic_id) }
            result << round
          end
        end
      end

      def resolve_targets(positions)
        nearest = rounds(positions.uniq).flat_map { |round| nearest_public_ids(round) }.uniq(&:last)
        return [] if nearest.empty?

        following = next_public_ids(nearest)
        nearest.map do |topic_id, comment_id|
          Target.new(topic_id: topic_id, comment_id: comment_id, next_comment_id: following[[ topic_id, comment_id ]])
        end
      end

      def nearest_public_ids(round)
        maxima = grouped_public(round) { |_, comment_id| comment_table[:id].lteq(comment_id) }.maximum(:id)
        round.filter_map { |topic_id, _| [ topic_id, maxima[topic_id] ] if maxima[topic_id] }
      end

      # The receipt for a comment covers pointers up to (but not including) the
      # next public comment in the same topic; beyond that the avatar belongs to
      # a later comment instead.
      def next_public_ids(nearest)
        rounds(nearest).each_with_object({}) do |round, result|
          minima = grouped_public(round) { |_, comment_id| comment_table[:id].gt(comment_id) }.minimum(:id)
          round.each { |topic_id, comment_id| result[[ topic_id, comment_id ]] = minima[topic_id] }
        end
      end

      def grouped_public(round)
        scopes = round.map do |topic_id, comment_id|
          Comment.where(creative_id: creative.id, topic_id: topic_id).where(yield(topic_id, comment_id))
        end
        creative.comments.public_only.merge(scopes.reduce { |combined, scope| combined.or(scope) }).group(:topic_id)
      end

      def readers_by_comment_id(targets)
        pointers = candidate_pointers(targets)
        return {} if pointers.empty?

        readable_user_ids = CreativeShare.readable_user_ids_from_shares(creative, pointers.map(&:user_id)).to_set
        named_pointer_keys = named_pointer_keys_for(targets)
        readable = pointers.select { |pointer| readable_user_ids.include?(pointer.user_id) }
        targets.to_h do |target|
          [ target.comment_id, readable.select { |pointer| covers?(pointer, target, named_pointer_keys) }.map(&:user) ]
        end
      end

      def candidate_pointers(targets)
        scopes = targets.map { |target| pointer_scope(target) }
        CommentReadPointer.where(creative: creative)
                          .merge(scopes.reduce { |combined, scope| combined.or(scope) })
                          .includes(user: { avatar_attachment: :blob })
                          .to_a
      end

      # Topic precedence is applied in Ruby below, so SQL only has to bracket the
      # watermark range and the two lanes that can possibly match.
      def pointer_scope(target)
        scope = CommentReadPointer.where(creative_id: creative.id, topic_id: [ target.topic_id, nil ].uniq)
                                  .where(pointer_table[:last_read_comment_id].gteq(target.comment_id))
        return scope unless target.next_comment_id

        scope.where(pointer_table[:last_read_comment_id].lt(target.next_comment_id))
      end

      # The retained legacy pointer is authoritative for a named topic only until
      # the user has a pointer of their own for it. That lookup spans every
      # pointer on the topic, not just the ones inside a rendered range.
      def named_pointer_keys_for(targets)
        topic_ids = targets.filter_map(&:topic_id)
        return Set.new if topic_ids.empty?

        CommentReadPointer.where(creative: creative, topic_id: topic_ids).pluck(:topic_id, :user_id).to_set
      end

      def covers?(pointer, target, named_pointer_keys)
        return false unless in_range?(pointer, target)
        return pointer.topic_id.nil? if target.topic_id.nil?
        return true if pointer.topic_id == target.topic_id

        pointer.topic_id.nil? && !named_pointer_keys.include?([ target.topic_id, pointer.user_id ])
      end

      def in_range?(pointer, target)
        return false if pointer.last_read_comment_id.nil? || pointer.last_read_comment_id < target.comment_id

        target.next_comment_id.nil? || pointer.last_read_comment_id < target.next_comment_id
      end

      def broadcast(comment_id, users, present_user_ids)
        Turbo::StreamsChannel.broadcast_update_to(
          [ creative, :comments ],
          target: "read_receipts_comment_#{comment_id}",
          partial: "collavre/comments/read_receipts",
          locals: { read_by_users: users, present_user_ids: present_user_ids }
        )
      end
    end
  end
end

module Collavre
  class CommentReadPointersController < ApplicationController
    LEGACY_TOPIC_WATERMARK_KEY = "_legacy"

    def update
      creative = Creative.find(params[:creative_id]).effective_origin
      topic = params[:topic_id].present? && creative.topics.find_by(id: params[:topic_id])
      return head :unprocessable_entity if params[:topic_id].present? && !topic

      last_ids = topic ? topic_last_id(creative, topic) : all_message_last_ids(creative)
      positions = Comments::ReadPointerWriter.new(creative: creative, user: Current.user).call(last_ids)
      Comments::ReadReceiptBroadcaster.new(creative: creative).call(positions)

      Comment.broadcast_badge(creative, Current.user)

      render json: { success: true }
    end

    private

    def topic_last_id(creative, topic)
      { topic.id => creative.comments.visible_to(Current.user).where(topic: topic).maximum(:id) }
    end

    # All Messages renders Main plus active topics, not archived ones. Do not
    # advance the retained legacy pointer here: an archived topic without its
    # own pointer falls back to it, so moving that watermark would silently mark
    # its hidden comments as read.
    def all_message_last_ids(creative)
      visible_comments = creative.comments.visible_to(Current.user)
      topic_watermarks, legacy_watermark = normalized_topic_watermarks(params[:topic_watermarks])
      return watermarked_last_ids(creative, visible_comments, topic_watermarks, legacy_watermark) if
        topic_watermarks.any? || legacy_watermark.positive?

      unwatermarked_last_ids(creative, visible_comments)
    end

    def normalized_topic_watermarks(rendered_topic_watermarks)
      raw_watermarks = rendered_topic_watermarks.respond_to?(:to_unsafe_h) ? rendered_topic_watermarks.to_unsafe_h : rendered_topic_watermarks.to_h
      topic_watermarks = raw_watermarks.filter_map do |topic_id, comment_id|
        [ topic_id.to_i, comment_id.to_i ] if topic_id.to_i.positive? && comment_id.to_i.positive?
      end.to_h

      [ topic_watermarks, raw_watermarks[LEGACY_TOPIC_WATERMARK_KEY].to_i ]
    end

    def watermarked_last_ids(creative, visible_comments, topic_watermarks, legacy_watermark)
      last_ids = bounded_topic_last_ids(creative, visible_comments, topic_watermarks)
      return last_ids unless legacy_watermark.positive?

      legacy_last_id = visible_comments.where(topic_id: nil).where("comments.id <= ?", legacy_watermark).maximum(:id)
      legacy_last_id ? last_ids.merge(nil => legacy_last_id) : last_ids
    end

    # Every rendered topic carries its own bound, so the maxima are OR-ed into a
    # single grouped query rather than one MAX per topic. Built from relations
    # rather than a SQL fragment: a hand-built string here would be safe (literal
    # template, bound values) but unprovably so to a scanner.
    def bounded_topic_last_ids(creative, visible_comments, topic_watermarks)
      topic_ids = creative.topics.where(id: topic_watermarks.keys).pluck(:id)
      return {} if topic_ids.empty?

      scopes = topic_ids.map do |topic_id|
        Comment.where(creative_id: creative.id, topic_id: topic_id)
               .where(Comment.arel_table[:id].lteq(topic_watermarks.fetch(topic_id)))
      end
      maxima = grouped_topic_maxima(visible_comments, scopes)
      topic_ids.index_with { |topic_id| maxima[topic_id] }
    end

    def unwatermarked_last_ids(creative, visible_comments)
      rendered_topic_ids_supplied = params.key?(:topic_ids)
      topics = rendered_topic_ids_supplied ? creative.topics.where(id: Array(params[:topic_ids])) : creative.topics
      topic_ids = topics.pluck(:id)
      maxima = visible_comments.where(topic_id: topic_ids).group(:topic_id).maximum(:id)
      last_ids = topic_ids.index_with { |topic_id| maxima[topic_id] }
      return last_ids if rendered_topic_ids_supplied

      legacy_client_last_ids(visible_comments, last_ids)
    end

    # Clients deployed before topic-scoped watermarks only send creative_id.
    # Preserve the previous creative-wide endpoint semantics for them: every
    # named topic, including archived topics, and the retained legacy lane
    # advance through the visible history.
    def legacy_client_last_ids(visible_comments, last_ids)
      legacy_last_id = visible_comments.where(topic_id: nil).maximum(:id)
      legacy_last_id ? last_ids.merge(nil => legacy_last_id) : last_ids
    end

    def grouped_topic_maxima(visible_comments, scopes)
      visible_comments.merge(scopes.reduce { |combined, scope| combined.or(scope) }).group(:topic_id).maximum(:id)
    end
  end
end

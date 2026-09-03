# frozen_string_literal: true

module Collavre
  module Comments
    class ListResponse
      LIMIT = 20
      LEGACY_TOPIC_WATERMARK_KEY = "_legacy"

      def initialize(controller:, creative:, history_scope_creative: creative)
        @controller = controller
        @creative = creative
        @history_scope_creative = history_scope_creative
      end

      def render
        return render_history if history_topic?

        comments, topic_id, all_messages = load_comments
        write_rendered_topic_headers(comments) if all_messages
        controller.render(**render_options(comments, topic_id))
      end

      private

      attr_reader :controller, :creative

      delegate :params, :response, to: :controller

      def history_topic?
        params[:topic_id].present? &&
          creative.topics.where(id: params[:topic_id], name: Creative::HISTORY_TOPIC_NAME).exists?
      end

      def render_history
        change_sets = CreativeChangeSet.for_creative_scope(@history_scope_creative)
          .visible_by_default.includes(:creative_changes, :user)
        change_sets = history_page(change_sets)
        response.headers["X-Topic-Id"] = params[:topic_id].to_s
        controller.render partial: "collavre/creative_change_sets/list",
                          locals: {
                            creative: @history_scope_creative,
                            change_sets: change_sets,
                            pagination: params[:before_id].present? || params[:after_id].present?
                          }
      end

      def history_page(scope)
        if params[:before_id].present?
          scope.where("creative_change_sets.id < ?", params[:before_id].to_i).limit(LIMIT).to_a.reverse
        elsif params[:after_id].present?
          scope.where("creative_change_sets.id > ?", params[:after_id].to_i)
            .reorder("creative_change_sets.id ASC").limit(LIMIT).to_a
        else
          scope.limit(LIMIT).to_a.reverse
        end
      end

      def load_comments
        visible_scope = creative.comments.visible_to(Current.user)
        topic_id = effective_topic_id(visible_scope)
        scope, all_messages = filtered_scope(visible_scope, topic_id)
        [ paginated_comments(scope), topic_id, all_messages ]
      end

      def effective_topic_id(visible_scope)
        return params[:topic_id].presence unless params[:around_comment_id].present?

        target_comment = visible_scope.find_by(id: params[:around_comment_id].to_i)
        return params[:topic_id].presence unless target_comment

        response.headers["X-Topic-Id"] = target_comment.topic_id.to_s
        target_comment.topic_id
      end

      def filtered_scope(visible_scope, topic_id)
        scope = visible_scope.with_attached_images.includes(:task, :topic, :comment_reactions, :comment_versions, :snapshot_as_result)
        scope = search_scope(scope)
        return [ scope.where(topic_id: topic_id).order(id: :desc), false ] if topic_id.present?

        [ exclude_archived_topics(scope).order(id: :desc), true ]
      end

      def search_scope(scope)
        search_words.reduce(scope) do |result, word|
          result.where("LOWER(comments.content) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(word)}%")
        end
      end

      def search_words
        params[:search].to_s.strip.downcase.split(/\s+/).first(Creatives::Filters::SearchFilter::MAX_SEARCH_WORDS)
      end

      def exclude_archived_topics(scope)
        archived_topic_ids = creative.topics.archived.pluck(:id)
        archived_topic_ids.any? ? scope.where.not(topic_id: archived_topic_ids) : scope
      end

      def paginated_comments(scope)
        return comments_around(scope) if params[:around_comment_id].present?
        return older_comments(scope) if params[:before_id].present?
        return newer_comments(scope) if params[:after_id].present?

        scope.limit(LIMIT).to_a.reverse
      end

      def comments_around(scope)
        target_id = params[:around_comment_id].to_i
        newer = scope.where("comments.id >= ?", target_id).reorder(id: :asc).limit(LIMIT / 2 + 1)
        older = scope.where("comments.id < ?", target_id).limit(LIMIT / 2)
        (older.to_a.reverse + newer.to_a).uniq
      end

      def older_comments(scope)
        scope.where("comments.id < ?", params[:before_id].to_i).limit(LIMIT).to_a.reverse
      end

      def newer_comments(scope)
        scope.where("comments.id > ?", params[:after_id].to_i).reorder(id: :asc).limit(LIMIT)
      end

      def write_rendered_topic_headers(comments)
        watermarks = comments.group_by(&:topic_id).transform_values { |items| items.map(&:id).max }
        legacy_watermark = watermarks.delete(nil)
        watermarks[LEGACY_TOPIC_WATERMARK_KEY] = legacy_watermark if legacy_watermark
        response.headers["X-Rendered-Topic-Ids"] = watermarks.keys.grep(Integer).sort.join(",")
        response.headers["X-Rendered-Topic-Watermarks"] = watermarks.to_json
      end

      def render_options(comments, topic_id)
        read_receipts = ReadReceiptIndex.new(creative: creative, comments: comments, topic_id: topic_id).receipts
        return pagination_options(comments, topic_id, read_receipts) if pagination_request?

        list_options(comments, topic_id, read_receipts)
      end

      def pagination_request?
        params[:after_id].present? || params[:before_id].present?
      end

      def pagination_options(comments, topic_id, read_receipts)
        {
          partial: "collavre/comments/comment", collection: comments, as: :comment,
          locals: receipt_locals(read_receipts, topic_id)
        }
      end

      def list_options(comments, topic_id, read_receipts)
        {
          partial: "collavre/comments/list",
          locals: receipt_locals(read_receipts, topic_id).merge(
            comments: comments, creative: creative, search: params[:search], current_topic: current_topic(comments, topic_id)
          )
        }
      end

      def receipt_locals(read_receipts, topic_id)
        { read_receipts: read_receipts, present_user_ids: CommentPresenceStore.list(creative.id), current_topic_id: topic_id }
      end

      def current_topic(comments, topic_id)
        creative.topics.find_by(id: topic_id) if comments.empty? && topic_id.present?
      end
    end
  end
end

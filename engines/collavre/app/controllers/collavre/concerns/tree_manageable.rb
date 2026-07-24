module Collavre
  module Concerns
    module TreeManageable
      extend ActiveSupport::Concern

      def reorder
        dragged_ids = Array(params[:dragged_ids]).map(&:presence).compact
        target_id = params[:target_id]
        direction = params[:direction]

        if dragged_ids.any?
          reorderer.reorder_multiple(
            dragged_ids: dragged_ids,
            target_id: target_id,
            direction: direction
          )
        else
          reorderer.reorder(
            dragged_id: params[:dragged_id],
            target_id: target_id,
            direction: direction
          )
        end
        head :ok
      rescue ::Creatives::Reorderer::Error
        head :unprocessable_entity
      end

      def link_drop
        result = reorderer.link_drop(
          dragged_id: params[:dragged_id],
          target_id: params[:target_id],
          direction: params[:direction]
        )

        new_creative = result.new_creative
        level = new_creative.ancestors.count + 1
        nodes = build_tree(
          [ new_creative ],
          params: params,
          expanded_state_map: {},
          level: level
        )

        render json: {
          nodes: nodes,
          creative_id: new_creative.id,
          parent_id: result.parent&.id,
          direction: result.direction
        }
      rescue ::Creatives::Reorderer::Error
        head :unprocessable_entity
      end

      def append_as_parent
        @parent_creative = Creative.find_by(id: params[:parent_id]).parent
        redirect_to new_creative_path(parent_id: @parent_creative&.id, child_id: params[:parent_id], tags: params[:tags])
      end

      def append_below
        target = Creative.find_by(id: params[:creative_id])
        redirect_to new_creative_path(parent_id: target&.parent_id, after_id: target&.id, tags: params[:tags])
      end

      def children
        parent = Creative.find(params[:id])
        effective = parent.effective_origin
        # user_id for expanded_state lookup - use owner's state for anonymous users
        state_user_id = Current.user&.id || effective.user_id

        # HTTP caching disabled for children endpoint:
        # Response depends on child updates, permission changes (CreativeSharesCache),
        # and UserCreativePreference. Tracking all dependencies reliably is expensive
        # (requires descendant_ids query). Stale 304 responses could leak data after
        # permission revocation. Re-enable when a cheap version key mechanism exists.
        # Use private + no-store to prevent any caching (proxy or browser).
        response.headers["Cache-Control"] = "private, no-store"

        has_filters = params[:tags].present? || params[:min_progress].present? || params[:max_progress].present?
        if has_filters
          result = ::Creatives::IndexQuery.new(user: Current.user, params: params.merge(id: params[:id])).call
          render_children_json(parent, state_user_id, result.allowed_creative_ids, result.progress_map)
        else
          render_children_json(parent, state_user_id, nil, nil)
        end
      end

      def unconvert
        base_creative = @creative.effective_origin
        parent = base_creative.parent
        if parent.nil?
          render json: { error: t("collavre.creatives.index.unconvert_no_parent") }, status: :unprocessable_entity and return
        end

        unless parent.has_permission?(Current.user, :feedback)
          render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden and return
        end

        unless base_creative.has_permission?(Current.user, :admin)
          render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden and return
        end

        markdown = helpers.render_creative_tree_markdown([ base_creative ])
        comment = nil

        ActiveRecord::Base.transaction do
          comment = parent.effective_origin.comments.create!(content: markdown, user: Current.user)
          base_creative.descendants.each(&:destroy!)
          base_creative.destroy!
        end

        render json: { comment_id: comment.id }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      private

      def render_children_json(parent, user_id, allowed_ids, progress_map)
        expanded_state_map = UserCreativePreference
                                .where(user_id: user_id, creative_id: parent.id)
                                .first&.expanded_status || {}
        children = parent.children_with_permission(Current.user)

        level = params[:level].to_i
        json_level = level.zero? ? 1 : level
        render json: {
          creatives: build_tree(
            children,
            params: params,
            expanded_state_map: expanded_state_map,
            level: json_level,
            select_mode: params[:select_mode] == "1",
            allowed_creative_ids: allowed_ids,
            progress_map: progress_map
          )
        }
      end
    end
  end
end

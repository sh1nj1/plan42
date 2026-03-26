module Collavre
  class Creative < ApplicationRecord
    module RealtimeBroadcastable
      extend ActiveSupport::Concern

      included do
        # NOTE: after_create_commit is NOT used here because CreateService
        # needs to call insert_at_position (resequence) BEFORE broadcast.
        # broadcast_creative_created is called explicitly from CreateService.
        after_update_commit :broadcast_creative_updated
        before_destroy :capture_broadcast_state
        after_destroy_commit :broadcast_creative_destroyed
      end

      # Public: called from CreateService after insert_at_position
      # @param after_id [Integer, nil] the creative ID this was inserted after (from user action)
      def broadcast_creative_created(after_id: nil)
        payload = broadcast_node_payload
        payload[:after_id] = after_id.presence&.to_i
        enqueue_broadcast(:created, payload)
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] ERROR in broadcast_creative_created: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end

      def broadcast_creative_updated
        # Skip broadcast when only progress changed (cascade from update_parent_progress).
        # The original creative's broadcast already includes ancestor progress in its payload,
        # so receivers update parent rows without needing separate broadcasts per ancestor.
        return if progress_only_change?

        enqueue_broadcast(:updated, broadcast_node_payload)
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] ERROR in broadcast_creative_updated: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end

      def capture_broadcast_state
        # Skip expensive queries for unshared personal creatives
        return if !origin_id && linked_creatives.none? && all_shared_users.none?

        # Capture before destroy — after destroy, associations are gone
        @_destroy_broadcast_users = find_broadcast_users
        @_destroy_linked_map = build_linked_creative_map(@_destroy_broadcast_users)
        @_destroy_payload = {
          id: id,
          parent_id: parent_id,
          ancestors: ancestors.map { |a| { id: a.id, progress: a.progress } }
        }
      end

      def broadcast_creative_destroyed
        return if @_destroy_broadcast_users.blank?

        current_user_id = Collavre.current_user&.id
        CreativeBroadcastJob.perform_later(
          id,
          "destroyed",
          current_user_id: current_user_id,
          payload: @_destroy_payload,
          options: {
            destroy_user_ids: @_destroy_broadcast_users.map(&:id),
            destroy_linked_map: @_destroy_linked_map
          }
        )
      end

      # Tree-renderer compatible node payload (matches TreeBuilder output)
      def broadcast_node_payload
        origin = safe_effective_origin
        desc_html = origin.effective_description
        desc_raw = description

        # Reload to get latest progress values (after update_parent_progress in after_save)
        fresh_ancestors = reload.ancestors

        {
          # Core node properties (tree_renderer.applyRowProperties)
          id: id,
          dom_id: "creative-#{id}",
          parent_id: parent_id,
          level: fresh_ancestors.size + 1,
          select_mode: false,
          can_write: true, # Refined per-user in JS if needed
          has_children: children.exists?,
          expanded: false,
          is_root: parent.nil?,
          archived: archived?,
          link_url: "/creatives?id=#{id}",
          origin_id: origin_id,
          sequence: sequence,
          previous_sibling_id: previous_sibling&.id,
          # Templates (for display)
          templates: {
            description_html: desc_html
            # progress_html intentionally omitted — minimal render would overwrite
            # the full server-rendered progress area (which includes chat badges etc.)
          },
          # Inline editor payload (for editor cache)
          inline_editor_payload: {
            description_raw_html: desc_raw,
            progress: progress,
            origin_id: origin_id
          },
          # Ancestors progress (for parent row updates)
          ancestors: fresh_ancestors.map { |a| { id: a.id, progress: a.progress } }
        }
      end

      # Returns true when update_parent_progress cascaded a progress-only save.
      # In that case, the child's broadcast already carries ancestor progress data,
      # so a separate broadcast for the parent is redundant.
      def progress_only_change?
        return false unless previous_changes.key?("progress")

        (previous_changes.keys - %w[progress updated_at]).empty?
      end

      def safe_effective_origin
        effective_origin
      rescue StandardError
        self
      end

      def previous_sibling
        scope = parent ? parent.children : Creative.where(parent_id: nil)
        scope.where("sequence < ?", sequence).order(sequence: :desc).first
      end

      # Enqueue broadcast as a background job to avoid blocking the request cycle.
      # Payload is built synchronously (needs fresh DB state), then delivery is async.
      def enqueue_broadcast(action, payload)
        CreativeBroadcastJob.perform_later(
          id,
          action.to_s,
          current_user_id: Collavre.current_user&.id,
          payload: payload
        )
      end

      # Build a map of user_id → linked_creative_id for this creative
      # So each user receives the correct ID for their view
      def build_linked_creative_map(users)
        origin = safe_effective_origin
        map = {}
        # If this IS the origin, find linked creatives for each user
        origin.linked_creatives.where(user: users).find_each do |linked|
          map[linked.user_id] = linked.id
        end
        # Also map ancestors' linked creatives
        map
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] Error building linked map: #{e.message}"
        {}
      end

      # Format progress text for a user (100% → completion mark if set)
      # Matches render_progress_value helper: when value==1 and completion_mark is not nil,
      # use it (even if blank — blank becomes non-breaking spaces in display)
      def format_progress_text(progress_value, user)
        pct = ((progress_value || 0) * 100).round
        if pct >= 100 && !user.completion_mark.nil?
          mark = user.completion_mark
          mark.blank? ? "" : mark
        else
          "#{pct}%"
        end
      end

      # Add per-user progress_text to payload and ancestors
      def add_progress_text!(data, target_user)
        # Main creative progress text
        if data.dig(:inline_editor_payload, :progress)
          data[:progress_text] = format_progress_text(data[:inline_editor_payload][:progress], target_user)
        end

        # Ancestor progress text
        data[:ancestors]&.each do |anc|
          anc[:progress_text] = format_progress_text(anc[:progress], target_user) if anc[:progress]
        end
      end

      def find_broadcast_users
        target = begin
          origin_id.present? && origin ? origin.effective_origin : effective_origin
        rescue ActiveRecord::RecordNotFound
          self
        end

        # Batch: collect all ancestor IDs + target in one query, then load shares in one query
        ancestor_ids = target.ancestor_ids  # closure_tree: single CTE query
        all_creative_ids = [ target.id ] + ancestor_ids

        # Owner users — single query
        owners = User.where(id: Creative.where(id: all_creative_ids).select(:user_id))

        # Shared users — single query (instead of N+1 per ancestor)
        shared_users = User.where(
          id: CreativeShare.where(creative_id: all_creative_ids).select(:user_id)
        )

        candidates = (owners + shared_users).compact.uniq

        # Filter: only users who actually have read permission on this creative
        # PermissionChecker uses creative_shares_caches (O(1) per user)
        candidates.select { |user| target.has_permission?(user, :read) }
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] Error finding users: #{e.message}"
        []
      end
    end
  end
end

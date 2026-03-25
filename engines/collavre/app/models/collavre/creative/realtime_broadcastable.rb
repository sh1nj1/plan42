module Collavre
  class Creative < ApplicationRecord
    module RealtimeBroadcastable
      extend ActiveSupport::Concern

      included do
        after_create_commit :broadcast_creative_created
        after_update_commit :broadcast_creative_updated
        after_destroy_commit :broadcast_creative_destroyed
      end

      private

      def broadcast_creative_created
        broadcast_creative_change(:created, broadcast_node_payload)
      end

      def broadcast_creative_updated
        broadcast_creative_change(:updated, broadcast_node_payload)
      end

      def broadcast_creative_destroyed
        broadcast_creative_change(:destroyed, broadcast_destroy_payload)
      end

      def broadcast_creative_change(action, data)
        target_users = find_broadcast_users
        current = Collavre.current_user
        target_users.reject! { |u| current && u.id == current.id }
        return if target_users.empty?

        payload = { action: action.to_s, creative: data }.to_json

        target_users.each do |target_user|
          Turbo::StreamsChannel.broadcast_action_to(
            [ target_user, :creative_tree ],
            action: :refresh_creative_tree,
            target: "creatives",
            attributes: { data: payload }
          )
        end
      end

      # Tree-renderer compatible node payload (matches TreeBuilder output)
      def broadcast_node_payload
        origin = safe_effective_origin
        desc_html = origin.effective_description
        desc_raw = description

        {
          # Core node properties (tree_renderer.applyRowProperties)
          id: id,
          dom_id: "creative-#{id}",
          parent_id: parent_id,
          level: ancestors.size + 1,
          has_children: children.exists?,
          expanded: false,
          is_root: parent.nil?,
          archived: archived?,
          link_url: "/creatives?id=#{id}",
          origin_id: origin_id,
          # Templates (for display)
          templates: {
            description_html: desc_html,
            progress_html: broadcast_progress_html
          },
          # Inline editor payload (for editor cache)
          inline_editor_payload: {
            description_raw_html: desc_raw,
            progress: progress,
            origin_id: origin_id
          },
          # Ancestors progress (for parent row updates)
          ancestors: ancestors.map { |a| { id: a.id, progress: a.progress } }
        }
      end

      def broadcast_destroy_payload
        {
          id: id,
          parent_id: parent_id,
          ancestors: (ancestors.map { |a| { id: a.id, progress: a.progress } } rescue [])
        }
      end

      # Simple progress HTML without view_context dependencies
      # Full progress_html (with comment badges etc.) requires view_context
      # so we render a minimal version; the user's own save already has full rendering
      def broadcast_progress_html
        pct = progress || 0
        %(<div class="creative-row-end"><span class="creative-progress">#{pct}%</span></div>)
      end

      def safe_effective_origin
        effective_origin
      rescue StandardError
        self
      end

      def find_broadcast_users
        target = begin
          origin_id.present? && origin ? origin.effective_origin : effective_origin
        rescue ActiveRecord::RecordNotFound
          self
        end

        users = []
        users << target.user if target.user
        users.concat(target.all_shared_users.map(&:user))

        target.ancestors.each do |ancestor|
          users << ancestor.user if ancestor.user
          users.concat(ancestor.all_shared_users.map(&:user))
        end

        users.compact.uniq
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] Error finding users: #{e.message}"
        []
      end
    end
  end
end

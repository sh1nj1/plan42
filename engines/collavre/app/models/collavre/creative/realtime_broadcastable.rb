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
        Rails.logger.info "[CreativeBroadcast] === broadcast_creative_created for creative##{id} seq=#{sequence} after_id=#{after_id} ==="
        payload = broadcast_node_payload
        payload[:after_id] = after_id.presence&.to_i
        broadcast_creative_change(:created, payload)
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] ERROR in broadcast_creative_created: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end

      def broadcast_creative_updated
        Rails.logger.info "[CreativeBroadcast] === after_update_commit fired for creative##{id} ==="
        broadcast_creative_change(:updated, broadcast_node_payload)
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] ERROR in broadcast_creative_updated: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end

      def capture_broadcast_state
        # Capture before destroy — after destroy, associations are gone
        @_destroy_broadcast_users = find_broadcast_users
        @_destroy_payload = {
          id: id,
          parent_id: parent_id,
          ancestors: ancestors.map { |a| { id: a.id, progress: a.progress } }
        }
      end

      def broadcast_creative_destroyed
        return if @_destroy_broadcast_users.blank?

        current = Collavre.current_user
        Rails.logger.info "[CreativeBroadcast] destroyed creative##{id} current_user=#{current&.email} target_users=#{@_destroy_broadcast_users.map(&:email)}"
        users = @_destroy_broadcast_users.reject { |u| current && u.id == current.id }
        return if users.empty?

        payload = { action: "destroyed", creative: @_destroy_payload }.to_json

        users.each do |target_user|
          Turbo::StreamsChannel.broadcast_action_to(
            [ target_user, :creative_tree ],
            action: :refresh_creative_tree,
            target: "creatives",
            attributes: { data: payload }
          )
        end
      end

      def broadcast_creative_change(action, data)
        target_users = find_broadcast_users
        current = Collavre.current_user
        Rails.logger.info "[CreativeBroadcast] #{action} creative##{data[:id]} current_user=#{current&.email} target_users=#{target_users.map(&:email)}"
        target_users.reject! { |u| current && u.id == current.id }
        return if target_users.empty?

        payload = { action: action.to_s, creative: data }.to_json
        Rails.logger.info "[CreativeBroadcast] Broadcasting to #{target_users.map(&:email)} payload_size=#{payload.size}"

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

        # Reload ancestors to get latest progress (after update_parent_progress in after_save)
        fresh_ancestors = self.class.find(id).ancestors

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
        pct = ((progress || 0) * 100).round
        %(<div class="creative-row-end"><span class="creative-progress">#{pct}%</span></div>)
      end

      def safe_effective_origin
        effective_origin
      rescue StandardError
        self
      end

      def previous_sibling
        siblings = if parent
                     parent.children.order(:sequence)
        else
                     Creative.roots.order(:sequence)
        end
        idx = siblings.to_a.index { |s| s.id == id }
        idx && idx > 0 ? siblings.to_a[idx - 1] : nil
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

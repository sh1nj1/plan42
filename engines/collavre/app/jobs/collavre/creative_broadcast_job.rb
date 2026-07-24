# frozen_string_literal: true

module Collavre
  # Asynchronous broadcast for creative CRUD changes.
  # Offloads per-user payload building and WebSocket delivery from the request cycle.
  class CreativeBroadcastJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: 1.second, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    # @param creative_id [Integer, Array<Integer>] single ID or array of IDs (for batch_created)
    # @param action [String] "created", "updated", "destroyed", or "batch_created"
    # @param current_user_id [Integer, nil] user who triggered the change (excluded from broadcast)
    # @param payload [Hash] pre-built node payload (for created/updated) or destroy payload
    # @param options [Hash] extra options (after_id, destroy_users, destroy_linked_map)
    def perform(creative_id, action, current_user_id: nil, payload: {}, options: {})
      case action
      when "batch_created"
        # creative_id is an array of IDs in tree order (parent before child).
        # Process sequentially within a single job to guarantee ordering.
        creative_ids = Array(creative_id)
        creative_ids.each do |cid|
          creative = Creative.find_by(id: cid)
          next unless creative

          creative.reload
          node_payload = creative.broadcast_node_payload
          node_payload[:previous_sibling_id] = creative.previous_sibling&.id
          broadcast_change(creative, "created", current_user_id, node_payload)
        end
        nil
      when "created", "updated"
        creative = Creative.find_by(id: creative_id)
        return unless creative

        broadcast_change(creative, action, current_user_id, payload.deep_symbolize_keys)
      when "destroyed"
        broadcast_destroyed(
          creative_id,
          current_user_id,
          payload.deep_symbolize_keys,
          options.deep_symbolize_keys
        )
      end
    rescue StandardError => e
      Rails.logger.error "[CreativeBroadcastJob] ERROR #{action} creative##{creative_id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    end

    private

    def broadcast_change(creative, action, current_user_id, data)
      target_users = creative.send(:find_broadcast_users)
      target_users.reject! { |u| current_user_id && u.id == current_user_id }
      return if target_users.empty?

      linked_map = creative.send(:build_linked_creative_map, target_users)

      # Batch-load all linked creatives for remapping (avoids N+1)
      origin_ids_to_remap = [ data[:parent_id], data[:after_id], data[:previous_sibling_id] ].compact
      ancestor_origin_ids = (data[:ancestors] || []).map { |a| a[:id] }.compact
      all_origin_ids = (origin_ids_to_remap + ancestor_origin_ids).uniq

      linked_by_user = {}
      if all_origin_ids.any?
        Creative.where(origin_id: all_origin_ids, user: target_users).find_each do |linked|
          linked_by_user[linked.user_id] ||= {}
          linked_by_user[linked.user_id][linked.origin_id] = linked.id
        end
      end

      target_users.each do |target_user|
        user_data = data.dup
        user_map = linked_by_user[target_user.id] || {}

        # Add linked_id
        linked_id = linked_map[target_user.id]
        user_data[:linked_id] = linked_id if linked_id

        # Remap IDs using batch-loaded map
        user_data[:parent_id] = user_map[user_data[:parent_id]] || user_data[:parent_id] if user_data[:parent_id]
        user_data[:after_id] = user_map[user_data[:after_id]] || user_data[:after_id] if user_data[:after_id]
        if user_data[:previous_sibling_id]
          user_data[:previous_sibling_id] = user_map[user_data[:previous_sibling_id]] || user_data[:previous_sibling_id]
        end

        # Remap ancestor IDs
        if user_data[:ancestors].present?
          user_data[:ancestors] = user_data[:ancestors].map do |anc|
            mapped_id = user_map[anc[:id]]
            mapped_id ? anc.merge(id: mapped_id, origin_id: anc[:id]) : anc
          end
        end

        # Per-user can_write permission
        user_data[:can_write] = creative.has_permission?(target_user, :write)

        # Per-user progress text
        creative.send(:add_progress_text!, user_data, target_user)

        # For created action, render per-user progress_html (includes chat button,
        # badge with turbo-cable-stream-source subscription, and progress span).
        # Existing rows already have this from server render; only new rows need it.
        if action == "created"
          user_data[:templates] ||= {}
          # target_user already passed find_broadcast_users permission check,
          # so we can skip the expensive permission_via_ancestors walk.
          user_data[:templates][:progress_html] = render_progress_html(creative, target_user, skip_permission_check: true)
        end

        json_payload = { action: action.to_s, creative: user_data }.to_json
        Turbo::StreamsChannel.broadcast_action_to(
          [ target_user, :creative_tree ],
          action: :refresh_creative_tree,
          target: "creatives",
          attributes: { data: json_payload }
        )
      end
    end

    def broadcast_destroyed(creative_id, current_user_id, payload, options)
      user_ids = options[:destroy_user_ids] || []
      return if user_ids.empty?

      users = User.where(id: user_ids)
      users = users.reject { |u| current_user_id && u.id == current_user_id }
      return if users.empty?

      linked_map = (options[:destroy_linked_map] || {}).transform_keys(&:to_i)

      # Batch-load linked creatives for ancestor remapping
      ancestor_origin_ids = (payload[:ancestors] || []).map { |a| a[:id] }.compact
      all_origin_ids = [ payload[:parent_id], *ancestor_origin_ids ].compact.uniq

      linked_by_user = {}
      if all_origin_ids.any?
        Creative.where(origin_id: all_origin_ids, user: users).find_each do |linked|
          linked_by_user[linked.user_id] ||= {}
          linked_by_user[linked.user_id][linked.origin_id] = linked.id
        end
      end

      users.each do |target_user|
        user_data = payload.dup
        user_map = linked_by_user[target_user.id] || {}

        user_data[:linked_id] = linked_map[target_user.id] if linked_map[target_user.id]
        user_data[:parent_id] = user_map[user_data[:parent_id]] || user_data[:parent_id] if user_data[:parent_id]

        if user_data[:ancestors].present?
          user_data[:ancestors] = user_data[:ancestors].map do |anc|
            mapped_id = user_map[anc[:id]]
            mapped_id ? anc.merge(id: mapped_id, origin_id: anc[:id]) : anc
          end
        end

        json_payload = { action: "destroyed", creative: user_data }.to_json
        Turbo::StreamsChannel.broadcast_action_to(
          [ target_user, :creative_tree ],
          action: :refresh_creative_tree,
          target: "creatives",
          attributes: { data: json_payload }
        )
      end
    end

    # Build progress HTML for a newly created creative.
    # New creatives always have 0 comments and initial progress, so we can
    # construct the HTML directly without a full view render.
    # Includes:
    # - turbo-cable-stream-source (per-user subscription for badge updates)
    # - comment button (hidden via no-comments class — 0 comments initially)
    # - progress span
    def render_progress_html(creative, user, skip_permission_check: false)
      origin = creative.effective_origin
      progress = creative.progress || 0
      pct = (progress * 100).round

      # Progress span (comes first, matching helper output order)
      css_class = pct >= 100 ? "creative-progress-complete" : "creative-progress-incomplete"
      completion_mark = Collavre::SystemSetting.completion_mark
      display_text = pct >= 100 && !completion_mark.nil? ? completion_mark : "#{pct}%"
      progress_span = %(<span class="#{css_class}">#{display_text}</span>)

      # Comment part — only render if user has feedback permission (matching helper behavior)
      # When skip_permission_check is true, the user was already verified by find_broadcast_users
      # (which checks :read permission on target + ancestors). Feedback permission is a subset
      # of read permission in practice, so we can safely render the comment button.
      comment_part = ""
      has_feedback = skip_permission_check ||
                     creative.has_permission?(user, :feedback) ||
                     permission_via_ancestors(creative, user, :feedback)
      if has_feedback
        # Generate signed stream name for turbo-cable-stream-source
        stream_name = Turbo::StreamsChannel.signed_stream_name([ user, origin, :comment_badge ])
        stream_tag = %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="#{stream_name}"></turbo-cable-stream-source>)

        # Badge (no comments yet — hidden)
        badge_id = "comment-badge-#{origin.id}"
        badge = %(<span id="#{badge_id}" class="badge" style="display:none" data-count="0" data-controller="comment-badge" data-comment-badge-has-comments-value="false"></span>)

        # Comment button — no-comments hides via visibility:hidden (0 comments initially)
        comment_icon = read_svg("comment.svg", class: "comment-icon")
        btn_classes = "comments-btn creative-action-btn no-comments"
        comment_btn = %(<button name="show-comments-btn" class="#{btn_classes}" data-creative-id="#{creative.id}" data-can-comment="true" data-creative-snippet="#{ERB::Util.html_escape(creative.creative_snippet)}">)
        comment_btn += %(#{comment_icon}#{badge}</button>)

        comment_part = "#{stream_tag}#{comment_btn}"
      end

      # Wrap in creative-row-end div — order: progress, then comment (matching helper)
      %(<div class="creative-row-end">#{progress_span}#{comment_part}</div>)
    rescue StandardError => e
      Rails.logger.warn "[CreativeBroadcastJob] render_progress_html failed for creative##{creative.id} user##{user.id}: #{e.message}"
      nil
    end

    # Check permission via ancestor chain (fallback when creative_shares_caches is not yet populated)
    def permission_via_ancestors(creative, user, permission)
      current = creative.parent
      while current
        return true if current.has_permission?(user, permission)
        current = current.parent
      end
      false
    end

    def read_svg(name, options = {})
      raw = self.class.svg_cache[name] ||= begin
        path = Rails.root.join("app", "assets", "images", name)
        File.exist?(path) ? File.read(path) : ""
      end
      return "" if raw.blank?

      svg = raw.dup
      if options[:class]
        escaped_class = ERB::Util.html_escape(options[:class])
        svg.sub!(/<svg\b/, %(<svg class="#{escaped_class}"))
      end
      # Safe: SVG source is a static asset file bundled with the app;
      # user-supplied class attribute is escaped above via html_escape.
      svg.html_safe # rubocop:disable Rails/OutputSafety
    end

    class << self
      def svg_cache
        @svg_cache ||= {}
      end
    end
  end
end

# frozen_string_literal: true

require "diff/lcs"

module Collavre
  module Creatives
    class ChangeSetDiff
      BLOCK_SEPARATOR = "\n\n---\n\n"
      # Git-style hunks: only lines within this many lines of a change are rendered.
      CONTEXT_LINES = 3
      GAP_ACTION = "~"

      def initialize(change_set, user:)
        @change_set = change_set
        @visibility = ChangeSetVisibility.new(user: user)
        @changes = @visibility.changes(change_set.creative_changes.order(:position))
        @changes_by_id = @changes.index_by(&:creative_id)
        @candidate_nodes = nil
        @parent_ids = {}
        @node_markdown = {}
      end

      def groups
        group_root_ids.map { |root_id| build_group(root_id) }
      end

      def change_count = @changes.size

      def fully_visible?
        change_count == @change_set.creative_changes.size && redacted_group_states.empty?
      end

      def revertible? = @change_set.origin != "sync" && actionable_changes.none? { |change| change.operation == "destroy" }

      def writable?
        @writable ||= PermissionFilter.new(user: @visibility.user)
          .readable_ids(actionable_changes.map(&:creative_id), min_permission: :write).any?
      end

      private

      def group_root_ids
        tops = touched_top_ids
        return [] if tops.empty?

        anchor_id = @change_set.anchor_creative_id
        anchor_visible = @changes_by_id.key?(anchor_id) || @visibility.visible_id?(anchor_id)
        return [ anchor_id ] if anchor_visible && tops.all? { |id| descendant_of?(id, anchor_id) }

        tops
      end

      def touched_top_ids
        touched = @changes_by_id.keys.to_set
        @changes.filter_map do |change|
          change.creative_id unless ancestor_ids(change.creative_id).any? { |id| touched.include?(id) }
        end
      end

      def descendant_of?(creative_id, ancestor_id)
        creative_id == ancestor_id || ancestor_ids(creative_id).include?(ancestor_id)
      end

      def ancestor_ids(creative_id)
        ids = []
        parent_id = parent_id_for(creative_id)
        while parent_id && !ids.include?(parent_id)
          ids << parent_id
          parent_id = parent_id_for(parent_id)
        end
        ids
      end

      def parent_id_for(creative_id)
        change = @changes_by_id[creative_id]
        return (change.after.presence || change.before)["parent_id"] if change

        return @parent_ids[creative_id] if @parent_ids.key?(creative_id)

        @parent_ids[creative_id] = Creative.unscoped.where(id: creative_id).pick(:parent_id)
      end

      def build_group(root_id)
        before = visible_document(root_id, :before)
        after = visible_document(root_id, :after)
        line_diff = Diff::LCS.sdiff(before.lines, after.lines)
        rows = hunk_rows(line_diff)
        {
          root_id: root_id,
          label: label_for(root_id),
          before: before,
          after: after,
          additions: line_diff.count { |change| %w[+ !].include?(change.action) },
          deletions: line_diff.count { |change| %w[- !].include?(change.action) },
          moved: moved_in_group?(root_id),
          inline_html: inline_html(rows),
          split_rows: rows
        }
      end

      def visible_document(root_id, state)
        return I18n.t("collavre.creative_history.snapshot_hidden") if redacted_group_states.include?([ root_id, state ])

        document(root_id, state)
      end

      def redacted_group_states
        @redacted_group_states ||= group_root_ids.product(%i[before after]).reject do |root_id, state|
          @visibility.historical_snapshots_visible?(changes_in_group(root_id), state)
        end.to_set
      end

      def changes_in_group(root_id)
        @changes.select { |change| descendant_of?(change.creative_id, root_id) }
      end

      def moved_in_group?(root_id)
        @changes.any? do |change|
          change.operation.in?(%w[move reorder]) && descendant_of?(change.creative_id, root_id)
        end
      end

      def document(root_id, state)
        nodes = base_snapshots.dup
        @changes.each do |change|
          snapshot = change.public_send(state)
          snapshot.empty? ? nodes.delete(change.creative_id) : nodes[change.creative_id] = snapshot
        end
        ordered_node_ids(root_id, nodes)
          .filter_map { |id| node_markdown(id, nodes[id], state) }
          .join(BLOCK_SEPARATOR)
      end

      def base_snapshots
        @base_snapshots ||= candidate_nodes.to_h { |creative| [ creative.id, History.snapshot(creative) ] }
      end

      # Untouched nodes render identically in both states and in every group, so
      # convert each one to markdown once instead of per document rebuild.
      def node_markdown(id, snapshot, state)
        return nil if snapshot.nil?

        key = [ id, @changes_by_id.key?(id) ? state : :base ]
        @node_markdown[key] ||= markdown_for(snapshot)
      end

      def candidate_nodes
        @candidate_nodes ||= begin
          root_ids = [ @change_set.anchor_creative_id, *@changes_by_id.keys ].compact.select(&:positive?)
          descendant_ids = CreativeHierarchy.where(ancestor_id: root_ids).pluck(:descendant_id)
          @visibility.nodes(Creative.unscoped.where(id: descendant_ids).to_a)
        end
      end

      def actionable_changes
        @actionable_changes ||= @changes.reject(&:review_skipped?)
      end

      def ordered_node_ids(root_id, nodes)
        children = nodes.keys.group_by { |id| nodes[id]["parent_id"] }
        walk = lambda do |id|
          return [] unless nodes.key?(id)

          descendants = Array(children[id]).sort_by { |child_id| [ nodes[child_id]["sequence"] || 0, child_id ] }
          [ id, *descendants.flat_map { |child_id| walk.call(child_id) } ]
        end
        walk.call(root_id)
      end

      def markdown_for(snapshot)
        return snapshot["markdown_source"].to_s if snapshot["content_type"] == "markdown"

        MarkdownConverter.html_to_markdown(snapshot["description"].to_s)
      end

      def label_for(root_id)
        change = @changes_by_id[root_id]
        snapshot = change&.after.presence unless redacted_group_states.include?([ root_id, :after ])
        snapshot ||= change&.before.presence unless redacted_group_states.include?([ root_id, :before ])
        snapshot ||= Creative.unscoped.find_by(id: root_id)&.then { |creative| History.snapshot(creative) }
        markdown_for(snapshot || {}).lines.first.to_s.sub(/\A#+\s*/, "").strip.presence || "##{root_id}"
      end

      # Renders changed lines plus CONTEXT_LINES around them. Documents are whole
      # subtrees, so emitting every unchanged line grows the payload without bound.
      def hunk_rows(line_diff)
        kept = kept_line_indexes(line_diff)
        rows = []
        skipped = 0
        line_diff.each_with_index do |change, index|
          next skipped += 1 unless kept.include?(index)

          rows << gap_row(skipped) if skipped.positive?
          skipped = 0
          rows << { action: change.action, before: change.old_element.to_s, after: change.new_element.to_s }
        end
        rows << gap_row(skipped) if skipped.positive?
        rows
      end

      def kept_line_indexes(line_diff)
        last = line_diff.size - 1
        line_diff.each_index.reduce(Set.new) do |kept, index|
          next kept if line_diff[index].action == "="

          kept.merge([ index - CONTEXT_LINES, 0 ].max..[ index + CONTEXT_LINES, last ].min)
        end
      end

      def gap_row(skipped)
        { action: GAP_ACTION, before: "", after: "", skipped: skipped }
      end

      def inline_html(rows)
        rows.map { |row| inline_row_html(row) }.join
      end

      def inline_row_html(row)
        return gap_html(row[:skipped]) if row[:action] == GAP_ACTION
        return ERB::Util.html_escape(row[:before]) if row[:action] == "="

        token_html(row[:before], row[:after])
      end

      def gap_html(skipped)
        ERB::Util.html_escape("#{I18n.t('collavre.creative_history.skipped_lines', count: skipped)}\n")
      end

      def token_html(before, after)
        Diff::LCS.sdiff(tokens(before), tokens(after)).map do |change|
          old_value = ERB::Util.html_escape(change.old_element.to_s)
          new_value = ERB::Util.html_escape(change.new_element.to_s)
          case change.action
          when "=" then old_value
          when "-" then "<del>#{old_value}</del>"
          when "+" then "<ins>#{new_value}</ins>"
          else "<del>#{old_value}</del><ins>#{new_value}</ins>"
          end
        end.join
      end

      def tokens(markdown)
        markdown.split(/(\s+|[[:punct:]])/).reject(&:empty?)
      end
    end
  end
end

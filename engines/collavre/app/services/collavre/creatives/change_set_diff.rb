# frozen_string_literal: true

require "diff/lcs"

module Collavre
  module Creatives
    class ChangeSetDiff
      BLOCK_SEPARATOR = "\n\n---\n\n"

      def initialize(change_set)
        @change_set = change_set
        @changes = change_set.creative_changes.order(:position).to_a
        @changes_by_id = @changes.index_by(&:creative_id)
      end

      def groups
        group_root_ids.map { |root_id| build_group(root_id) }
      end

      private

      def group_root_ids
        tops = touched_top_ids
        anchor_id = @change_set.anchor_creative_id
        return [ anchor_id ] if anchor_id && tops.all? { |id| descendant_of?(id, anchor_id) }

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

        Creative.unscoped.where(id: creative_id).pick(:parent_id)
      end

      def build_group(root_id)
        before = document(root_id, :before)
        after = document(root_id, :after)
        additions, deletions = line_counts(before, after)
        {
          root_id: root_id,
          label: label_for(root_id),
          before: before,
          after: after,
          additions: additions,
          deletions: deletions,
          moved: moved_in_group?(root_id),
          inline_html: inline_html(before, after),
          split_rows: split_rows(before, after)
        }
      end

      def moved_in_group?(root_id)
        @changes.any? do |change|
          change.operation.in?(%w[move reorder]) && descendant_of?(change.creative_id, root_id)
        end
      end

      def document(root_id, state)
        nodes = candidate_nodes(root_id).to_h { |creative| [ creative.id, History.snapshot(creative) ] }
        @changes.each do |change|
          snapshot = change.public_send(state)
          snapshot.empty? ? nodes.delete(change.creative_id) : nodes[change.creative_id] = snapshot
        end
        ordered_node_ids(root_id, nodes).filter_map { |id| markdown_for(nodes[id]) }.join(BLOCK_SEPARATOR)
      end

      def candidate_nodes(root_id)
        roots = Creative.unscoped.where(id: [ root_id, *@changes_by_id.keys ])
        roots.flat_map { |creative| creative.self_and_descendants.to_a }.uniq(&:id)
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
        snapshot = @changes_by_id[root_id]&.after.presence ||
                   @changes_by_id[root_id]&.before.presence ||
                   Creative.unscoped.find_by(id: root_id)&.then { |creative| History.snapshot(creative) }
        markdown_for(snapshot || {}).lines.first.to_s.sub(/\A#+\s*/, "").strip.presence || "##{root_id}"
      end

      def inline_html(before, after)
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

      def split_rows(before, after)
        Diff::LCS.sdiff(before.lines, after.lines).map do |change|
          { action: change.action, before: change.old_element.to_s, after: change.new_element.to_s }
        end
      end

      def line_counts(before, after)
        changes = Diff::LCS.sdiff(before.lines, after.lines)
        additions = changes.count { |change| %w[+ !].include?(change.action) }
        deletions = changes.count { |change| %w[- !].include?(change.action) }
        [ additions, deletions ]
      end

      def tokens(markdown)
        markdown.split(/(\s+|[[:punct:]])/).reject(&:empty?)
      end
    end
  end
end

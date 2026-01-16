require "test_helper"

module Creatives
  class AncestorFilterTest < ActiveSupport::TestCase
    class FakeViewContext
      include Rails.application.routes.url_helpers
      def embed_youtube_iframe(_content); ""; end
      def render_creative_progress(_creative, select_mode: false); ""; end
      def svg_tag(name, **args); ""; end
      def link_to(_path, *args); block_given? ? yield : ""; end
      def creative_path(creative, params = {}); "/creatives/#{creative.id}"; end
      def children_creative_path(creative, params = {}); "/children"; end
      def creative_link_view_path(link_id); "/l/#{link_id}"; end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new

      # Setup Tree
      # A (Tag1) -> B -> C
      # A -> B -> D (Tag1)
      # X -> Y

      @root_a = Creative.create!(user: @user, description: "A", sequence: 1)
      @node_b = Creative.create!(user: @user, parent: @root_a, description: "B", sequence: 1)
      @node_c = Creative.create!(user: @user, parent: @node_b, description: "C", sequence: 1)
      @node_d = Creative.create!(user: @user, parent: @node_b, description: "D", sequence: 2)

      @root_x = Creative.create!(user: @user, description: "X", sequence: 2)
      @node_y = Creative.create!(user: @user, parent: @root_x, description: "Y", sequence: 1)

      @tag_label_creative = Creative.create!(user: @user, description: "Tag1")
      @tag_label = Label.create!(creative: @tag_label_creative, owner: @user)

      Tag.create!(creative_id: @root_a.id, label: @tag_label)
      Tag.create!(creative_id: @node_d.id, label: @tag_label)

      # Ensure hierarchy is built (closure_tree should handle it)
      @root_a.reload
      @node_d.reload
    end

    test "IndexQuery calculates allowed_creative_ids including ancestors" do
      params = { tags: [ @tag_label.id ] }
      query = Creatives::IndexQuery.new(user: @user, params: params)
      result = query.call

      assert_not_nil result.allowed_creative_ids

      allowed = result.allowed_creative_ids.map(&:to_s)

      # A is tagged -> A is in allowed
      assert_includes allowed, @root_a.id.to_s

      # D is tagged. Ancestors of D are B, A.
      # So B should be in allowed.
      assert_includes allowed, @node_b.id.to_s
      assert_includes allowed, @node_d.id.to_s

      # C, X, Y should NOT be in allowed
      refute_includes allowed, @node_c.id.to_s
      refute_includes allowed, @root_x.id.to_s
      refute_includes allowed, @node_y.id.to_s

      # Result creatives should contain Root A
      result_ids = result.creatives.pluck(:id).map(&:to_s)
      assert_includes result_ids, @root_a.id.to_s
      refute_includes result_ids, @root_x.id.to_s
    end

    test "TreeBuilder preserves structure for filtered nodes" do
      # Simulate IndexQuery result
      allowed_ids = [ @root_a.id, @node_b.id, @node_d.id ].map(&:to_s).to_set

      builder = Creatives::TreeBuilder.new(
        user: @user,
        params: { tags: [ @tag_label.id ] },
        view_context: @view_context,
        expanded_state_map: {},
        select_mode: false,
        max_level: 10,
        allowed_creative_ids: allowed_ids
      )

      # Start with roots filtered
      roots = [ @root_a ] # IndexQuery would return this

      nodes = builder.build(roots)

      # A should be present
      node_a = nodes.find { |n| n[:id] == @root_a.id }
      assert_not_nil node_a

      # Structure:
      # A should have children loaded (because filters applied)
      # Children of A in 'nodes' list?
      # TreeBuilder returns flattened list if recursively built?
      # Wait, TreeBuilder returns `[ {..., children_container: { nodes: [...] } } ]`?
      # Let's check TreeBuilder implementation.
      # `children_nodes = load_children_now ? build_nodes(...) : []`
      # `children_container: ... nodes: children_nodes`
      # So it nests children in `children_container[:nodes]`.

      assert node_a[:children_container][:loaded], "Should be loaded"
      children_a = node_a[:children_container][:nodes]

      # B should be present in children of A
      node_b = children_a.find { |n| n[:id] == @node_b.id }
      assert_not_nil node_b

      # Children of B
      assert node_b[:children_container][:loaded], "B should be loaded"
      children_b = node_b[:children_container][:nodes]

      # D should be present
      node_d = children_b.find { |n| n[:id] == @node_d.id }
      assert_not_nil node_d

      # C should NOT be present (skipped)
      node_c = children_b.find { |n| n[:id] == @node_c.id }
      assert_nil node_c
    end

    test "IndexQuery calculates filtered progress as average of matched items" do
      # Setup for progress test - use leaf nodes to avoid closure_tree auto-updates
      # Create fresh creatives without children to control progress values directly
      leaf_a = Creative.create!(user: @user, description: "LeafA", progress: 0.5)
      leaf_b = Creative.create!(user: @user, description: "LeafB", progress: 1.0)
      leaf_x = Creative.create!(user: @user, description: "LeafX", progress: 0.1)

      # Note: Label.after_create automatically tags the label's creative
      # So tag_label2_creative will also be matched (progress 0.0)
      tag_label2_creative = Creative.create!(user: @user, description: "Tag2", progress: 0.0)
      tag_label2 = Label.create!(creative: tag_label2_creative, owner: @user)
      Tag.create!(creative_id: leaf_a.id, label: tag_label2)
      Tag.create!(creative_id: leaf_b.id, label: tag_label2)
      Tag.create!(creative_id: leaf_x.id, label: tag_label2)

      # Tag2 Filter - new simpler calculation
      # Matched: leaf_a, leaf_b, leaf_x, tag_label2_creative (auto-tagged)
      # Overall progress = average of all matched items' progress
      # (0.5 + 1.0 + 0.1 + 0.0) / 4 = 0.4

      params = { tags: [ tag_label2.id ] }
      query = Creatives::IndexQuery.new(user: @user, params: params)
      result = query.call

      expected_overall = (0.5 + 1.0 + 0.1 + 0.0) / 4.0
      assert_in_delta expected_overall, result.overall_progress, 0.01

      # Verify Progress Map - each item shows its actual progress
      map = result.progress_map
      assert_in_delta 0.5, map[leaf_a.id.to_s], 0.01
      assert_in_delta 1.0, map[leaf_b.id.to_s], 0.01
      assert_in_delta 0.1, map[leaf_x.id.to_s], 0.01
      assert_in_delta 0.0, map[tag_label2_creative.id.to_s], 0.01
    end
  end
end

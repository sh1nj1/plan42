require "test_helper"

module Creatives
  class TreeBuilderTest < ActiveSupport::TestCase
    class FakeViewContext
      include Rails.application.routes.url_helpers

      def embed_youtube_iframe(_content)
        "<iframe></iframe>"
      end

      def render_creative_progress(_creative, select_mode: false)
        "<progress data-select='#{select_mode}'></progress>"
      end

      def svg_tag(name, className: nil, width: nil, height: nil)
        "<svg data-name='#{name}' data-class='#{className}' data-width='#{width}' data-height='#{height}'></svg>"
      end

      def link_to(_path, *args)
        block_given? ? yield : ""
      end

      def creative_path(creative, params = {})
        path = "/creatives/#{creative.id}"
        if params.any?
          query = params.map { |k, v| "#{k}=#{v}" }.join("&")
          path += "?#{query}"
        end
        path
      end

      def children_creative_path(creative, params = {})
        level = params[:level]
        select_mode = params[:select_mode]
        link_parent_id = params[:link_parent_id]
        query_parts = [ "level=#{level}", "select_mode=#{select_mode}" ]
        query_parts << "link_parent_id=#{link_parent_id}" if link_parent_id
        "/creatives/#{creative.id}/children?#{query_parts.join('&')}"
      end

      def creative_link_view_path(link_id)
        "/l/#{link_id}"
      end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new
    end

    test "includes tagged descendants when parent does not match" do
      parent = Creative.create!(user: @user, progress: 0.1, description: "Parent")
      child = Creative.create!(user: @user, parent: parent, progress: 0.3, description: "Child")
      label_creative = Creative.create!(user: @user, description: "Tagged")
      label = Label.create!(creative: label_creative, owner: @user)
      Tag.create!(creative_id: child.id, label: label)

      # With the new FilterPipeline architecture, filtering is done before TreeBuilder
      # TreeBuilder receives allowed_creative_ids which includes both matched items and their ancestors
      # Both parent (ancestor) and child (matched) are in allowed_ids, so both are rendered
      allowed_ids = Set.new([ child.id.to_s, parent.id.to_s ])

      builder = build_tree_builder(tags: [ label.id ], allowed_creative_ids: allowed_ids)
      nodes = builder.build([ parent ])

      # Both parent and child are rendered in the tree
      # Parent is at level 1, child is nested at level 2
      assert_equal [ parent.id ], nodes.pluck(:id)
      assert_equal [ 1 ], nodes.pluck(:level)

      # Child is in the children_container nodes
      parent_node = nodes.first
      assert parent_node[:children_container].present?
      child_nodes = parent_node[:children_container][:nodes]
      assert_equal [ child.id ], child_nodes.pluck(:id)
      assert_equal [ 2 ], child_nodes.pluck(:level)
    end

    test "includes inline editor payload data" do
      creative = Creative.create!(user: @user, progress: 0.42, description: "Inline Data")

      builder = build_tree_builder
      nodes = builder.build([ creative ])

      payload = nodes.first[:inline_editor_payload]
      assert_equal creative.effective_description, payload[:description_raw_html]
      assert_in_delta creative.progress, payload[:progress]
      assert_nil payload[:origin_id]
    end

    test "direct child is not marked as linked even if CreativeLink exists from same parent" do
      parent = Creative.create!(user: @user, description: "Parent")
      direct_child = Creative.create!(user: @user, parent: parent, description: "Direct Child")

      # Create a CreativeLink from parent to direct_child (same relationship as parent_id)
      creative_link = CreativeLink.create!(
        parent_id: parent.id,
        origin_id: direct_child.id,
        created_by: @user
      )

      builder = build_tree_builder(parent_id: parent.id)
      nodes = builder.build([ direct_child ])

      node = nodes.first
      assert_equal direct_child.id, node[:id]
      assert_equal false, node[:is_linked], "Direct child should not be marked as linked"
      assert_nil node[:link_id], "Direct child should not have link_id"
      assert_equal "/creatives/#{direct_child.id}", node[:link_url], "Should use regular creative path"
    end

    test "linked creative from different parent is marked as linked" do
      parent = Creative.create!(user: @user, description: "Parent")
      other_parent = Creative.create!(user: @user, description: "Other Parent")
      linked_origin = Creative.create!(user: @user, parent: other_parent, description: "Linked Origin")

      # Create a CreativeLink from parent to linked_origin
      creative_link = CreativeLink.create!(
        parent_id: parent.id,
        origin_id: linked_origin.id,
        created_by: @user
      )

      builder = build_tree_builder(parent_id: parent.id)
      nodes = builder.build([ linked_origin ])

      node = nodes.first
      assert_equal linked_origin.id, node[:id]
      assert_equal true, node[:is_linked], "Linked origin should be marked as linked"
      assert_equal creative_link.id, node[:link_id], "Should have correct link_id"
      assert_equal "/l/#{creative_link.id}", node[:link_url], "Should use creative_link_view path"
    end

    test "filtered_children_for does not mark direct children as linked" do
      parent = Creative.create!(user: @user, description: "Parent")
      direct_child = Creative.create!(user: @user, parent: parent, description: "Direct Child")
      other_origin = Creative.create!(user: @user, description: "Other Origin")

      # Link from parent to direct_child (redundant, should be ignored)
      CreativeLink.create!(parent_id: parent.id, origin_id: direct_child.id, created_by: @user)
      # Link from parent to other_origin (valid link)
      link_to_other = CreativeLink.create!(parent_id: parent.id, origin_id: other_origin.id, created_by: @user)

      builder = build_tree_builder(expanded_state_map: { parent.id.to_s => true })
      nodes = builder.build([ parent ])

      parent_node = nodes.first
      children_nodes = parent_node[:children_container][:nodes]

      # Find direct_child and other_origin in children
      direct_child_node = children_nodes.find { |n| n[:id] == direct_child.id }
      other_origin_node = children_nodes.find { |n| n[:id] == other_origin.id }

      assert_not_nil direct_child_node, "Direct child should be in children"
      assert_equal false, direct_child_node[:is_linked], "Direct child should not be linked"

      assert_not_nil other_origin_node, "Other origin should be in children via link"
      assert_equal true, other_origin_node[:is_linked], "Other origin should be linked"
      assert_equal link_to_other.id, other_origin_node[:link_id]
    end

    private

    def build_tree_builder(params = {})
      parent_id = params.delete(:parent_id)
      allowed_creative_ids = params.delete(:allowed_creative_ids)
      expanded_state_map = params.delete(:expanded_state_map) || {}

      Creatives::TreeBuilder.new(
        user: @user,
        params: ActionController::Parameters.new(params),
        view_context: @view_context,
        expanded_state_map: expanded_state_map,
        select_mode: false,
        max_level: 6,
        allowed_creative_ids: allowed_creative_ids,
        parent_id: parent_id
      )
    end
  end
end

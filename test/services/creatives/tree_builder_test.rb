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

    private

    def build_tree_builder(params = {})
      Creatives::TreeBuilder.new(
        user: @user,
        params: ActionController::Parameters.new(params),
        view_context: @view_context,
        expanded_state_map: {},
        select_mode: false,
        max_level: 6
      )
    end
  end
end

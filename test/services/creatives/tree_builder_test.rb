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

      def creative_path(creative)
        "/creatives/#{creative.id}"
      end

      def children_creative_path(creative, level:, select_mode:)
        "/creatives/#{creative.id}/children?level=#{level}&select_mode=#{select_mode}"
      end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new
    end

    test "skips creatives not in allowed_creative_ids" do
      parent = Creative.create!(user: @user, progress: 0.1, description: "Parent")
      child = Creative.create!(user: @user, parent: parent, progress: 0.3, description: "Child")

      # Only child is in allowed_creative_ids (simulating FilterPipeline result without ancestor)
      allowed_ids = Set.new([ child.id.to_s ])
      builder = build_tree_builder(allowed_creative_ids: allowed_ids)
      nodes = builder.build([ parent ])

      # Parent is skipped, child is rendered at level 1
      assert_equal [ child.id ], nodes.pluck(:id)
      assert_equal [ 1 ], nodes.pluck(:level)
    end

    test "shows ancestors when included in allowed_creative_ids" do
      parent = Creative.create!(user: @user, progress: 0.1, description: "Parent")
      child = Creative.create!(user: @user, parent: parent, progress: 0.3, description: "Child")

      # Both parent and child are in allowed_creative_ids (normal FilterPipeline result with ancestors)
      allowed_ids = Set.new([ parent.id.to_s, child.id.to_s ])
      builder = build_tree_builder(allowed_creative_ids: allowed_ids)
      nodes = builder.build([ parent ])

      # Parent is shown at level 1, child is shown as its children
      assert_equal [ parent.id ], nodes.pluck(:id)
      assert_equal [ 1 ], nodes.pluck(:level)
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

    def build_tree_builder(allowed_creative_ids: nil, params: {})
      Creatives::TreeBuilder.new(
        user: @user,
        params: ActionController::Parameters.new(params),
        view_context: @view_context,
        expanded_state_map: {},
        select_mode: false,
        max_level: 6,
        allowed_creative_ids: allowed_creative_ids
      )
    end
  end
end

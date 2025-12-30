require "test_helper"

module Creatives
  class TreeBuilderTest < ActiveSupport::TestCase
    class FakeViewContext
      include Rails.application.routes.url_helpers

      def embed_youtube_iframe(_content)
        "<iframe></iframe>"
      end

      def render_creative_progress(_creative, select_mode: false, progress_value: nil)
        "<progress data-select='#{select_mode}' data-progress='#{progress_value}'></progress>"
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

      def children_creative_path(creative, params = {})
        query = params
        "/creatives/#{creative.id}/children?#{query.to_query}"
      end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new
    end

    test "includes tagged descendants when parent does not match" do
      parent = Creative.create!(user: @user, progress: 0.1, description: "Parent")
      child = Creative.create!(user: @user, parent: parent, progress: 0.3, description: "Child")
      label = Label.create!(owner: @user, name: "Tagged")
      Tag.create!(creative_id: child.id, label: label)

      params = { tags: [ label.id ] }
        filter_result = Creatives::FilteredTreeResolver.new(
          user: @user,
          params: params,
          calculate_progress: false
        ).call([ parent ])
        builder = build_tree_builder(params: params, filter_result: filter_result)
        nodes = builder.build([ parent ])

        assert_equal [ parent.id, child.id ].to_set, filter_result.allowed_ids
        assert_equal [ parent.id ], nodes.pluck(:id)
        assert_equal [ 1 ], nodes.pluck(:level)

        child_nodes = nodes.first.dig(:children_container, :nodes) || []
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

    def build_tree_builder(params: {}, filter_result: nil)
      params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params
      filter_result ||= Creatives::FilteredTreeResolver.new(
        user: @user,
        params: params,
        calculate_progress: false
      ).call([])

      Creatives::TreeBuilder.new(
        user: @user,
        params: params,
        view_context: @view_context,
        expanded_state_map: {},
        select_mode: false,
        max_level: 6,
        filtered_ids: filter_result.allowed_ids,
        progress_map: filter_result.progress_map
      )
    end
  end
end

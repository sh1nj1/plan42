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

      def svg_tag(name, class: nil, width: nil, height: nil)
        "<svg data-name='#{name}' data-class='#{class}' data-width='#{width}' data-height='#{height}'></svg>"
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

    test "includes tagged descendants when parent does not match" do
      parent = Creative.create!(user: @user, progress: 0.1)
      child = Creative.create!(user: @user, parent: parent, progress: 0.3)
      label = Label.create!(owner: @user, name: "Tagged")
      Tag.create!(creative: child, label: label)

      builder = build_tree_builder(tags: [label.id])
      nodes = builder.build([parent])

      assert_equal [child.id], nodes.pluck(:id)
      assert_equal [1], nodes.pluck(:level)
    end

    test "includes descendants that satisfy progress filters" do
      parent = Creative.create!(user: @user, progress: 0.1)
      child = Creative.create!(user: @user, parent: parent, progress: 0.9)

      builder = build_tree_builder(min_progress: 0.5)
      nodes = builder.build([parent])

      assert_equal [child.id], nodes.pluck(:id)
      assert_equal [1], nodes.pluck(:level)
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

require "test_helper"

module Creatives
  class WorkspaceTreeBuilderTest < ActiveSupport::TestCase
    class FakeViewContext
      def strip_tags(value)
        ActionController::Base.helpers.strip_tags(value)
      end

      def creative_path(creative)
        "/creatives/#{creative.id}"
      end

      def collavre
        self
      end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new
    end

    test "returns only readable creatives that have children" do
      root = Creative.create!(user: @user, description: "<strong>Root</strong>")
      branch = Creative.create!(user: @user, parent: root, description: "Branch")
      Creative.create!(user: @user, parent: branch, description: "Leaf")
      Creative.create!(user: @user, description: "Root leaf")

      nodes = build_tree([ root ] + Creative.where(description: "Root leaf").to_a)

      assert_equal [ root.id ], nodes.pluck(:id)
      assert_equal "Root", nodes.first[:label]
      assert_equal "/creatives/#{root.id}", nodes.first[:url]
      assert_equal [ branch.id ], nodes.first[:children].pluck(:id)
      assert_empty nodes.first[:children].first[:children]
    end

    test "hides a branch whose children are not readable" do
      root = Creative.create!(user: @user, description: "Private child root")
      Creative.create!(user: users(:two), parent: root, description: "Foreign child")

      assert_empty build_tree([ root ])
    end

    test "stops recursion at the configured display level" do
      root = Creative.create!(user: @user, description: "Level 1")
      branch = Creative.create!(user: @user, parent: root, description: "Level 2")
      Creative.create!(user: @user, parent: branch, description: "Level 3")

      nodes = build_tree([ root ], max_level: 1)

      assert_equal [ root.id ], nodes.pluck(:id)
      assert_empty nodes.first[:children]
    end

    private

    def build_tree(creatives, max_level: 6)
      Collavre::Creatives::WorkspaceTreeBuilder.new(
        user: @user,
        view_context: @view_context,
        max_level: max_level
      ).build(creatives)
    end
  end
end

require "test_helper"

module Creatives
  class WorkspaceTreeBuilderTest < ActiveSupport::TestCase
    class FakeViewContext
      def strip_tags(value)
        ActionController::Base.helpers.strip_tags(value)
      end

      def creatives_path(id:)
        "/creatives?id=#{id}"
      end

      def collavre
        self
      end
    end

    setup do
      @user = users(:one)
      @view_context = FakeViewContext.new
    end

    test "returns every readable root without loading their children" do
      root = Creative.create!(user: @user, description: "<strong>Root</strong>")
      branch = Creative.create!(user: @user, parent: root, description: "Branch")
      Creative.create!(user: @user, parent: branch, description: "Leaf")
      root_leaf = Creative.create!(user: @user, description: "Root leaf")

      nodes = build_tree([ root, root_leaf ])

      assert_equal [ root.id, root_leaf.id ], nodes.pluck(:id)
      assert_equal "Root", nodes.first[:label]
      assert_equal root.creative_snippet, nodes.first[:snippet]
      assert nodes.first[:can_comment]
      assert_equal "/creatives?id=#{root.id}", nodes.first[:url]
      assert nodes.first[:has_children]
      assert_empty nodes.first[:children]
    end

    test "keeps a childless root visible with its own metadata" do
      root_leaf = Creative.create!(user: @user, description: "<em>Root leaf</em>")

      nodes = build_tree([ root_leaf ])

      assert_equal [ root_leaf.id ], nodes.pluck(:id)
      assert_equal "Root leaf", nodes.first[:label]
      assert_equal root_leaf.creative_snippet, nodes.first[:snippet]
      assert nodes.first[:can_comment]
      assert_equal "/creatives?id=#{root_leaf.id}", nodes.first[:url]
      refute nodes.first[:has_children]
      assert_empty nodes.first[:children]
    end

    test "keeps a childless root visible when it is expanded" do
      root_leaf = Creative.create!(user: @user, description: "Root leaf")

      nodes = build_tree([ root_leaf ], expanded_ids: [ root_leaf.id ])

      assert_equal [ root_leaf.id ], nodes.pluck(:id)
      refute nodes.first[:has_children]
      assert_empty nodes.first[:children]
    end

    test "hides childless creatives below the root level" do
      root = Creative.create!(user: @user, description: "Root")
      branch = Creative.create!(user: @user, parent: root, description: "Branch")
      Creative.create!(user: @user, parent: branch, description: "Leaf")
      Creative.create!(user: @user, parent: root, description: "Root child leaf")

      nodes = build_tree([ root ], expanded_ids: [ root.id ])

      assert_equal [ branch.id ], nodes.first[:children].pluck(:id)
    end

    test "loads only requested branches" do
      root = Creative.create!(user: @user, description: "Root")
      branch = Creative.create!(user: @user, parent: root, description: "Branch")
      Creative.create!(user: @user, parent: branch, description: "Leaf")

      nodes = build_tree([ root ], expanded_ids: [ root.id ])

      assert_equal [ branch.id ], nodes.first[:children].pluck(:id)
      refute nodes.first[:children].first[:has_children]
      assert_empty nodes.first[:children].first[:children]
    end

    test "renders a root whose children are not readable as childless" do
      root = Creative.create!(user: @user, description: "Private child root")
      Creative.create!(user: users(:two), parent: root, description: "Foreign child")

      nodes = build_tree([ root ], expanded_ids: [ root.id ])

      assert_equal [ root.id ], nodes.pluck(:id)
      refute nodes.first[:has_children]
      assert_empty nodes.first[:children]
    end

    test "hides a non-root branch whose children are not readable" do
      root = Creative.create!(user: @user, description: "Root")
      branch = Creative.create!(user: @user, parent: root, description: "Private child branch")
      Creative.create!(user: users(:two), parent: branch, description: "Foreign child")

      nodes = build_tree([ root ], expanded_ids: [ root.id ])

      assert_equal [ root.id ], nodes.pluck(:id)
      refute nodes.first[:has_children]
      assert_empty nodes.first[:children]
    end

    test "expands requested paths beyond the former display level" do
      root = Creative.create!(user: @user, description: "Level 1")
      path = [ root ]
      6.times do |index|
        path << Creative.create!(user: @user, parent: path.last, description: "Level #{index + 2}")
      end
      Creative.create!(user: @user, parent: path.last, description: "Leaf")

      nodes = build_tree([ root ], expanded_ids: path.map(&:id))

      rendered_ids = []
      remaining = nodes
      until remaining.empty?
        rendered_ids << remaining.first.fetch(:id)
        remaining = remaining.first.fetch(:children)
      end
      assert_equal path.map(&:id), rendered_ids
    end

    test "stops linked shell cycles without hiding the shell" do
      origin = Creative.create!(user: @user, description: "Cyclic origin")
      shell = Creative.create!(user: @user, parent: origin, origin: origin, description: "Cyclic shell")

      nodes = build_tree([ origin ], expanded_ids: [ origin.id, shell.id ])

      assert_equal [ origin.id ], nodes.pluck(:id)
      assert_equal [ shell.id ], nodes.first.fetch(:children).pluck(:id)
      refute nodes.first.fetch(:children).first.fetch(:has_children)
      assert_empty nodes.first.fetch(:children).first.fetch(:children)
    end

    test "batches linked origins and permission ranks for each level" do
      shells = 4.times.map do |index|
        origin = Creative.create!(user: users(:two), description: "Shared root #{index}")
        Creative.create!(user: users(:two), parent: origin, description: "Shared child #{index}")
        CreativeShare.create!(creative: origin, user: @user, permission: :feedback)
        origin.create_linked_creative_for_user(@user)
        Creative.find_by!(user: @user, origin: origin)
      end
      shell_ids = shells.map(&:id)
      fresh_shells = Creative.where(id: shell_ids).order(:id).to_a
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        queries << sql unless payload[:cached] || payload[:name] == "SCHEMA"
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        build_tree(fresh_shells, expanded_ids: shell_ids)
      end

      child_scans = queries.grep(/SELECT "creatives"\."id", "creatives"\."parent_id".*WHERE "creatives"\."parent_id"/i)
      per_node_queries = queries.grep(/(?:FROM "creatives"|creative_shares_cache).*LIMIT 1/i)
      assert_equal 2, child_scans.size, "expected one child scan per inspected level"
      assert_empty per_node_queries, "expected batched workspace tree reads, got:\n#{per_node_queries.join("\n")}"
    end

    private

    def build_tree(creatives, expanded_ids: [])
      Collavre::Creatives::WorkspaceTreeBuilder.new(
        user: @user,
        view_context: @view_context,
        expanded_ids: expanded_ids
      ).build(creatives)
    end
  end
end

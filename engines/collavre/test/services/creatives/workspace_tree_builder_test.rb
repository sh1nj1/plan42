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

    test "returns only readable creatives that have children" do
      root = Creative.create!(user: @user, description: "<strong>Root</strong>")
      branch = Creative.create!(user: @user, parent: root, description: "Branch")
      Creative.create!(user: @user, parent: branch, description: "Leaf")
      Creative.create!(user: @user, description: "Root leaf")

      nodes = build_tree([ root ] + Creative.where(description: "Root leaf").to_a)

      assert_equal [ root.id ], nodes.pluck(:id)
      assert_equal "Root", nodes.first[:label]
      assert_equal root.creative_snippet, nodes.first[:snippet]
      assert nodes.first[:can_comment]
      assert_equal "/creatives?id=#{root.id}", nodes.first[:url]
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
        build_tree(fresh_shells)
      end

      per_node_queries = queries.grep(/(?:collavre_creatives|creative_shares_cache).*LIMIT 1/i)
      assert_empty per_node_queries, "expected batched workspace tree reads, got:\n#{per_node_queries.join("\n")}"
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

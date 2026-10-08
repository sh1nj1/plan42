require "test_helper"

module Collavre
  module Creatives
    class PublicTreeBuilderTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @root = Creative.create!(user: @owner, description: "Root")
        @a = Creative.create!(user: @owner, parent: @root, description: "A", sequence: 1)
        @b = Creative.create!(user: @owner, parent: @root, description: "B", sequence: 2)
        @a1 = Creative.create!(user: @owner, parent: @a, description: "A1", sequence: 1)
        perform_enqueued_jobs { CreativeShare.create!(creative: @root, user: nil, permission: :read) }
      end

      def outline(nodes)
        nodes.map { |node| [ node.creative.description, outline(node.children) ] }
      end

      test "returns the readable subtree in order" do
        builder = PublicTreeBuilder.new(@root)

        assert_equal [ [ "A", [ [ "A1", [] ] ] ], [ "B", [] ] ], outline(builder.call)
        assert_not builder.truncated?
      end

      test "resolves permission for the anonymous reader, not the signed-in one" do
        perform_enqueued_jobs { CreativeShare.create!(creative: @b, user: nil, permission: :no_access) }
        Current.stub(:user, @owner) do
          assert_equal [ [ "A", [ [ "A1", [] ] ] ] ], outline(PublicTreeBuilder.new(@root).call)
        end
      end

      test "skips archived children" do
        @b.update!(archived_at: Time.current)

        assert_equal [ [ "A", [ [ "A1", [] ] ] ] ], outline(PublicTreeBuilder.new(@root).call)
      end

      test "renders a linked child from its public origin" do
        source = Creative.create!(user: users(:two), description: "Source")
        Creative.create!(user: users(:two), parent: source, description: "Source child")
        perform_enqueued_jobs { CreativeShare.create!(creative: source, user: nil, permission: :read) }
        Creative.create!(user: @owner, parent: @b, origin: source, sequence: 1)

        nodes = PublicTreeBuilder.new(@root).call

        assert_equal [ "B", [ [ "Source", [ [ "Source child", [] ] ] ] ] ], outline(nodes).last
      end

      test "hides a linked child whose origin is private" do
        source = Creative.create!(user: users(:two), description: "Private source")
        Creative.create!(user: @owner, parent: @b, origin: source, sequence: 1)

        assert_equal [ "B", [] ], outline(PublicTreeBuilder.new(@root).call).last
      end

      test "expands a creative linked back up the tree only once" do
        Creative.create!(user: @owner, parent: @a1, origin: @a, sequence: 1)

        nodes = PublicTreeBuilder.new(@root).call

        assert_equal [ "A", [ [ "A1", [ [ "A", [] ] ] ] ] ], outline(nodes).first
      end

      test "stops at the node limit and reports truncation" do
        builder = PublicTreeBuilder.new(@root, limit: 2)

        assert_equal [ [ "A", [] ], [ "B", [] ] ], outline(builder.call)
        assert builder.truncated?
      end

      test "stops at the depth limit and reports truncation" do
        builder = PublicTreeBuilder.new(@root, max_depth: 1)

        assert_equal [ [ "A", [] ], [ "B", [] ] ], outline(builder.call)
        assert builder.truncated?
      end

      test "a depth limit that reaches only leaves is not truncated" do
        builder = PublicTreeBuilder.new(@root, max_depth: 2)

        builder.call

        assert_not builder.truncated?
      end
    end
  end
end

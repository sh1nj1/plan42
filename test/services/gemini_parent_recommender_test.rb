require "test_helper"

class GeminiParentRecommenderTest < ActiveSupport::TestCase
  test "recommend only includes writable creatives in the tree" do
    user = users(:one)
    other_user = users(:two)

    # Writable creatives (owned by user)
    writable_parent = Creative.create!(user: user, description: "Writable Parent", progress: 0.0)
    writable_child = Creative.create!(user: user, description: "Writable Child", progress: 0.0, parent: writable_parent)
    # Add grandchild to make writable_child a parent, so it's included by joins(:children)
    Creative.create!(user: user, description: "Writable Grandchild", progress: 0.0, parent: writable_child)

    # Read-only or No-access creatives (owned by other)
    no_access_creative = Creative.create!(user: other_user, description: "No Access", progress: 0.0)
    # Add child to ensure it's not filtered by joins(:children) but by permission
    Creative.create!(user: other_user, description: "No Access Child", progress: 0.0, parent: no_access_creative)

    # Mock client to inspect the tree text
    client_mock = Minitest::Mock.new

    # We expect `recommend_parent_ids` to be called.
    # We check the passed `tree_text` to ensure it contains only writable items.
    client_mock.expect(:recommend_parent_ids, []) do |tree_text, _desc|
      assert_match(/Writable Parent/, tree_text)
      assert_match(/Writable Child/, tree_text)
      # Grandchild might not appear if it itself doesn't have children (it's a leaf),
      # but Writable Child is now a parent so it appears.

      refute_match(/No Access/, tree_text)
      true
    end

    recommender = GeminiParentRecommender.new(client: client_mock)

    # We need a context creative (does not matter much for the tree generation part, but used for `user` extraction)
    context_creative = Creative.create!(user: user, description: "New Item", progress: 0.0)

    recommender.recommend(context_creative)

    client_mock.verify
  end

  test "filters children that do not have write permission" do
    user = users(:one)
    other_user = users(:two)

    writable_parent = Creative.create!(user: user, description: "Writable Parent", progress: 0.0)

    # Child is owned by another user and has no explicit shares.
    # Therefore, `user` has no write permission on `mixed_child` and it should be filtered out.
    mixed_child = Creative.create!(user: other_user, description: "Mixed Child", progress: 0.0, parent: writable_parent)
    # Add grandchild so mixed_child is a parent
    Creative.create!(user: other_user, description: "Mixed Grandchild", progress: 0.0, parent: mixed_child)

    # We need to ensure `user` cannot write to `mixed_child`.
    # Assuming `has_permission?` returns false for other's creative.

    client_mock = Minitest::Mock.new
    client_mock.expect(:recommend_parent_ids, []) do |tree_text, _desc|
      assert_match(/Writable Parent/, tree_text)
      refute_match(/Mixed Child/, tree_text)
      true
    end

    recommender = GeminiParentRecommender.new(client: client_mock)
    context_creative = Creative.create!(user: user, description: "New Item", progress: 0.0)

    recommender.recommend(context_creative)

    client_mock.verify
  end
end

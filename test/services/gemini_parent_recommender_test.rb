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
    # Assuming default logic: non-owners might have read or no access depending on visibility.
    # We will mock `has_permission?` to be sure, or rely on distinct owners if that suffices.
    # To be safe and test logic explicitly, we can mock or use specific setup if we knew the permission model well.
    # But let's try assuming ownership = write, non-ownership = different.

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

    # Child with NO write permission (simulated)
    # We will stub has_permission? for this specific instance if possible?
    # Or create a scenario.
    # Let's use stubbing.
    restricted_child = Creative.create!(user: user, description: "Restricted Child", progress: 0.0, parent: writable_parent)

    # We'll use a wrapper or define a singleton method on the instance,
    # BUT GeminiParentRecommender fetches fresh instances from DB.
    # So we must rely on data-driven permissions or mock the method on ALL instances of that object.

    # Since `GeminiParentRecommender` queries `Creative...`, we can't easily stub the loaded objects *before* they are loaded
    # unless we stub `Creative.distinct...`.

    # However, if we assume the standard permission model:
    # If the user is NOT the owner, and not a collaborator, they might not have write access.
    # Let's retry creating a mixed ownership tree.
    # Parent owned by User. Child owned by Other.

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

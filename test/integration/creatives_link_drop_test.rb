require "test_helper"

class CreativesLinkDropTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "linkdrop@example.com", password: "pw", name: "User")
    @root = Creative.create!(user: @user, description: "Root", progress: 0.5, sequence: 0)
    @target = Creative.create!(user: @user, parent: @root, description: "Target", sequence: 0, progress: 0.2)
    @dragged = Creative.create!(user: @user, parent: @root, description: "Dragged", sequence: 1, progress: 0.3)
    Creative.create!(user: @user, parent: @dragged, description: "Child of dragged", progress: 0.1)

    sign_in_as(@user)
  end

  test "creates linked creative as child" do
    post link_drop_creatives_path, params: {
      dragged_id: @dragged.id,
      target_id: @target.id,
      direction: "child"
    }, as: :json

    assert_response :ok
    parsed = JSON.parse(response.body)
    assert parsed["link_id"].present?

    creative_link = CreativeLink.find(parsed["link_id"])
    assert_equal @dragged.id, creative_link.origin_id
    assert_equal @target.id, creative_link.parent_id
    assert_kind_of Array, parsed["nodes"]
    # nodes contain the origin, not the link
    assert_equal @dragged.id, parsed["nodes"].dig(0, "id")
    assert_equal "creative-#{@dragged.id}", parsed["nodes"].dig(0, "dom_id")
  end

  test "inserts linked creative before target when moving up" do
    other = Creative.create!(user: @user, parent: @root, description: "Other", sequence: 2, progress: 0.4)

    post link_drop_creatives_path, params: {
      dragged_id: @dragged.id,
      target_id: other.id,
      direction: "up"
    }, as: :json

    assert_response :ok
    creative_link = CreativeLink.find(JSON.parse(response.body)["link_id"])
    assert_equal @root.id, creative_link.parent_id
    assert_equal @dragged.id, creative_link.origin_id
  end

  test "returns 422 for invalid parameters" do
    post link_drop_creatives_path, params: { dragged_id: 0, target_id: 0, direction: "up" }, as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 when linking would create a cycle under descendant" do
    assert_no_difference -> { CreativeLink.count } do
      post link_drop_creatives_path, params: {
        dragged_id: @root.id,
        target_id: @target.id,
        direction: "child"
      }, as: :json

      assert_response :unprocessable_entity
    end
  end

  test "returns 422 when linking near descendant would create a cycle" do
    grandchild = Creative.create!(user: @user, parent: @target, description: "Grandchild", sequence: 0)

    assert_no_difference -> { CreativeLink.count } do
      post link_drop_creatives_path, params: {
        dragged_id: @root.id,
        target_id: grandchild.id,
        direction: "down"
      }, as: :json

      assert_response :unprocessable_entity
    end
  end

  test "returns 422 when linking to descendant's linked creative" do
    # Create a CreativeLink to @target (instead of old-style Creative with origin_id)
    linked_target_link = CreativeLink.create!(
      parent: Creative.create!(user: @user, description: "Link parent"),
      origin: @target,
      created_by: @user
    )

    assert_no_difference -> { CreativeLink.count } do
      post link_drop_creatives_path, params: {
        dragged_id: @root.id,
        target_id: @target.id,  # Use origin directly since we no longer have shell creatives
        direction: "child"
      }, as: :json

      assert_response :unprocessable_entity
    end
  end
end

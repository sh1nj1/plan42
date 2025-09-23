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
    assert parsed["creative_id"].present?

    linked = Creative.find(parsed["creative_id"])
    assert_equal @dragged.id, linked.origin_id
    assert_equal @target.id, linked.parent_id
    assert_includes parsed["html"], "creative-tree"
    assert_includes parsed["html"], "has-children"
  end

  test "inserts linked creative before target when moving up" do
    other = Creative.create!(user: @user, parent: @root, description: "Other", sequence: 2, progress: 0.4)

    post link_drop_creatives_path, params: {
      dragged_id: @dragged.id,
      target_id: other.id,
      direction: "up"
    }, as: :json

    assert_response :ok
    linked = Creative.find(JSON.parse(response.body)["creative_id"])
    assert_equal @root.id, linked.parent_id

    ordered_ids = @root.children.order(:sequence).pluck(:id)
    assert_includes ordered_ids, linked.id
    assert ordered_ids.index(linked.id) < ordered_ids.index(other.id)
  end

  test "returns 422 for invalid parameters" do
    post link_drop_creatives_path, params: { dragged_id: 0, target_id: 0, direction: "up" }, as: :json
    assert_response :unprocessable_entity
  end
end

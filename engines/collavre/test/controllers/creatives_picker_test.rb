require "test_helper"

# Covers the lightweight "simple" JSON payload used by the creative picker popup:
# browsable mini-tree (has_children) and flat search results with breadcrumbs.
class CreativesPickerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")

    @token = "zqpicker"
    # root -> mid -> leaf (leaf matches the search token)
    @root = Creative.create!(user: @user, description: "Picker Root", sequence: 900)
    @mid = Creative.create!(user: @user, parent: @root, description: "Picker Mid", sequence: 1)
    @leaf = Creative.create!(user: @user, parent: @mid, description: "Picker Leaf #{@token}", sequence: 1)
    @root.reload
  end

  test "simple browse of roots reports has_children" do
    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body

    root_row = body.find { |c| c["id"] == @root.id }
    assert_not_nil root_row, "root creative should be present"
    assert_equal true, root_row["has_children"]
    assert root_row.key?("progress")
  end

  test "simple browse of children returns next level with has_children" do
    get collavre.creatives_path(format: :json, simple: true, id: @root.id)

    assert_response :success
    body = JSON.parse(response.body)
    mid_row = body.find { |c| c["id"] == @mid.id }
    assert_not_nil mid_row
    assert_equal true, mid_row["has_children"]

    # Leaf has no children
    get collavre.creatives_path(format: :json, simple: true, id: @mid.id)
    body = JSON.parse(response.body)
    leaf_row = body.find { |c| c["id"] == @leaf.id }
    assert_not_nil leaf_row
    assert_equal false, leaf_row["has_children"]
  end

  test "simple browse reports has_children for a linked-creative shell via its origin" do
    # Origin owned by another user, with a child stored under the origin.
    origin = Creative.create!(user: users(:two), description: "Shared Origin", sequence: 950)
    Creative.create!(user: users(:two), parent: origin, description: "Shared Child", sequence: 1)

    # Linked shell owned by the signed-in user appears as a root for them.
    shell = Creative.create!(user: @user, origin_id: origin.id, parent_id: nil)

    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    shell_row = body.find { |c| c["id"] == shell.id }
    assert_not_nil shell_row, "linked shell should appear as a root"
    # Children live under the origin (parent_id == origin.id), not the shell.
    # has_children must follow the effective origin to match what expansion shows.
    assert_equal true, shell_row["has_children"]
    # The effective origin id is exposed so the client can map search
    # breadcrumbs (origin ids) back to this shell node.
    assert_equal origin.id, shell_row["origin_id"]
  end

  test "simple browse omits origin_id for non-linked creatives" do
    get collavre.creatives_path(format: :json, simple: true)

    assert_response :success
    body = JSON.parse(response.body)
    root_row = body.find { |c| c["id"] == @root.id }
    assert_not_nil root_row
    assert_not root_row.key?("origin_id"), "non-linked creative should not carry origin_id"
  end

  test "simple search annotates results with ancestor breadcrumb path" do
    get collavre.creatives_path(format: :json, simple: true, search: @token)

    assert_response :success
    body = JSON.parse(response.body)
    match = body.find { |c| c["id"] == @leaf.id }
    assert_not_nil match, "matched leaf should be returned"

    path = match["path"]
    assert_kind_of Array, path
    # Ordered root -> immediate parent, self excluded
    assert_equal [ @root.id, @mid.id ], path.map { |p| p["id"] }
    assert_equal "Picker Root", path.first["description"]
  end

  test "simple search results are capped at SIMPLE_SEARCH_LIMIT" do
    limit = ::Collavre::Creatives::IndexQuery::SIMPLE_SEARCH_LIMIT
    capped_token = "zqcap"
    (limit + 5).times do |i|
      Creative.create!(user: @user, parent: @root, description: "Cap #{capped_token} #{i}", sequence: 100 + i)
    end

    get collavre.creatives_path(format: :json, simple: true, search: capped_token)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal limit, body.length
  end
end

require "test_helper"

# `has_children` drives the expand toggle, and the toggle's target is a separate
# request (Creatives#children). The two answers are now derived by different code
# — a batched presence scan for the flag, `children_with_permission` for the
# expansion — so they have to be pinned to each other.
#
# Drift in either direction is a real bug: a toggle whose expansion comes back
# empty tells the user that children exist which they are not allowed to see,
# and a missing toggle hides a subtree they can reach.
class CreativesHasChildrenParityTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @other = users(:two)
    sign_in_as(@user, password: "password")

    @root = Creative.create!(user: @user, description: "Parity root", sequence: 900)
  end

  test "a child the user cannot read grants no toggle" do
    node = Creative.create!(user: @user, parent: @root, description: "node", sequence: 1)
    Creative.create!(user: @other, parent: node, description: "someone else's", sequence: 1)

    assert_equal false, has_children?(node), "an unreadable child must not surface a toggle"
    assert_empty expand(node), "sanity: expanding really does show nothing"
  end

  test "a readable child grants a toggle that expands to it" do
    node = Creative.create!(user: @user, parent: @root, description: "node", sequence: 1)
    child = Creative.create!(user: @user, parent: node, description: "mine", sequence: 1)

    assert_equal true, has_children?(node)
    assert_equal [ child.id ], expand(node).map { |n| n["id"] }
  end

  test "an archived-only child grants no toggle unless archived rows are shown" do
    node = Creative.create!(user: @user, parent: @root, description: "node", sequence: 1)
    child = Creative.create!(user: @user, parent: node, description: "archived", sequence: 1)
    child.archive!

    assert_equal false, has_children?(node)
    assert_equal true, has_children?(node, show_archived: true)
  end

  # Children of a linked shell hang off the origin, not the shell row, so a
  # presence lookup keyed on the shell's own id would report every shell childless.
  test "a linked shell reports the origin's children" do
    origin = Creative.create!(user: @user, description: "origin", sequence: 901)
    Creative.create!(user: @user, parent: origin, description: "origin child", sequence: 1)
    shell = Creative.create!(user: @user, parent: @root, origin: origin, description: "shell", sequence: 2)

    assert_equal true, has_children?(shell)
  end

  test "a childless node grants no toggle" do
    node = Creative.create!(user: @user, parent: @root, description: "leaf", sequence: 1)

    assert_equal false, has_children?(node)
  end

  private

  # Reads the flag off the browse tree the same way the client does.
  def has_children?(creative, show_archived: false)
    params = { format: :json, id: @root.id }
    params[:show_archived] = true if show_archived
    get collavre.creatives_path(**params)
    assert_response :success

    node = JSON.parse(response.body).fetch("creatives").find { |n| n["id"] == creative.id }
    assert_not_nil node, "creative #{creative.id} should be rendered under the root"
    node.fetch("has_children")
  end

  # What clicking the toggle actually fetches.
  def expand(creative)
    get collavre.children_creative_path(creative, format: :json)
    assert_response :success
    JSON.parse(response.body).fetch("creatives")
  end
end

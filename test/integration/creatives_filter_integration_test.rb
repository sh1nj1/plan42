require "test_helper"

class CreativesFilterIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "filter_test@example.com", password: "pw", name: "User")
    @root = Creative.create!(user: @user, description: "Root", progress: 0.5, sequence: 0)
    @child_complete = Creative.create!(user: @user, parent: @root, description: "Complete", sequence: 0, progress: 1.0)
    @child_incomplete = Creative.create!(user: @user, parent: @root, description: "Incomplete", sequence: 1, progress: 0.0)
    # Add grandchildren to test deeper filtering
    @grandchild_incomplete = Creative.create!(user: @user, parent: @child_incomplete, description: "Grandchild Incomplete", sequence: 0, progress: 0.0)

    sign_in_as(@user)
  end

  test "incomplete filter returns incomplete children" do
    get creatives_path(id: @root.id, min_progress: "0", max_progress: "0.99", format: :json)

    assert_response :success
    parsed = JSON.parse(response.body)
    creative_ids = parsed["creatives"].map { |c| c["id"] }

    assert_includes creative_ids, @child_incomplete.id, "Incomplete child should be in response"
    assert_not_includes creative_ids, @child_complete.id, "Complete child should not be in response"
  end

  test "incomplete filter with multiple children at same level" do
    # Create more incomplete children like the real data
    @child2 = Creative.create!(user: @user, parent: @root, description: "Child2", sequence: 2, progress: 0.0)
    @child3 = Creative.create!(user: @user, parent: @root, description: "Child3", sequence: 3, progress: 0.25)
    @child4 = Creative.create!(user: @user, parent: @root, description: "Child4", sequence: 4, progress: 0.0)

    get creatives_path(id: @root.id, min_progress: "0", max_progress: "0.99", format: :json)

    assert_response :success
    parsed = JSON.parse(response.body)
    creative_ids = parsed["creatives"].map { |c| c["id"] }

    # All incomplete children should be present
    assert_includes creative_ids, @child_incomplete.id
    assert_includes creative_ids, @child2.id
    assert_includes creative_ids, @child3.id
    assert_includes creative_ids, @child4.id
    assert_not_includes creative_ids, @child_complete.id
  end

  test "filter with existing data like creative 7" do
    # Use existing creative 7 and 4679 if they exist
    skip "Using fixture data" unless Creative.exists?(7) && Creative.exists?(4679)

    sign_in_as(User.find(1))

    get creatives_path(id: 7, min_progress: "0", max_progress: "0.99", format: :json)

    assert_response :success
    parsed = JSON.parse(response.body)
    creative_ids = parsed["creatives"].map { |c| c["id"] }

    assert_includes creative_ids, 4679, "Creative 4679 should be in filtered response for creative 7"
  end
end

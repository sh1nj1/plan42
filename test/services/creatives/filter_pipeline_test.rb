require "test_helper"

module Creatives
  class FilterPipelineTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
    end

    test "progress filter includes ancestors via virtual hierarchy" do
      parent = Creative.create!(user: @user, description: "Parent", progress: 0.0)
      origin = Creative.create!(user: @user, description: "Origin", progress: 1.0)

      CreativeLink.create!(parent: parent, origin: origin, created_by: @user)

      result = FilterPipeline.new(
        user: @user,
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: [ parent.id, origin.id ])
      ).call

      # origin이 매칭됨
      assert_includes result.matched_ids, origin.id, "Origin should be matched"

      # parent도 allowed (origin의 가상 조상)
      assert_includes result.allowed_ids, parent.id.to_s, "Parent should be in allowed_ids"
    end

    test "search finds content in linked subtree" do
      parent = Creative.create!(user: @user, description: "Parent")
      origin = Creative.create!(user: @user, description: "Origin")
      child = Creative.create!(user: @user, parent: origin, description: "Contains keyword here")

      CreativeLink.create!(parent: parent, origin: origin, created_by: @user)

      result = FilterPipeline.new(
        user: @user,
        params: { search: "keyword" },
        scope: Creative.where(id: [ parent.id, origin.id, child.id ])
      ).call

      # child가 매칭됨
      assert_includes result.matched_ids, child.id, "Child should be matched"

      # parent도 allowed (virtual hierarchy를 통해)
      assert_includes result.allowed_ids, parent.id.to_s, "Parent should be in allowed_ids via virtual hierarchy"
    end

    test "tag filter includes ancestors" do
      parent = Creative.create!(user: @user, description: "Parent")
      child = Creative.create!(user: @user, parent: parent, description: "Tagged Child")

      # Create label and tag
      label_creative = Creative.create!(user: @user, description: "Label")
      label = Label.create!(creative: label_creative, owner: @user)
      Tag.create!(creative_id: child.id, label: label)

      result = FilterPipeline.new(
        user: @user,
        params: { tags: [ label.id ] },
        scope: Creative.where(id: [ parent.id, child.id ])
      ).call

      # child가 매칭됨
      assert_includes result.matched_ids, child.id, "Tagged child should be matched"

      # parent도 allowed (조상)
      assert_includes result.allowed_ids, parent.id.to_s, "Parent should be in allowed_ids"
    end

    test "combines multiple filters with intersection" do
      parent = Creative.create!(user: @user, description: "Parent", progress: 0.0)
      child1 = Creative.create!(user: @user, parent: parent, description: "Child 1", progress: 1.0)
      child2 = Creative.create!(user: @user, parent: parent, description: "Child 2", progress: 0.5)

      # Create label and tag on both children
      label_creative = Creative.create!(user: @user, description: "Label")
      label = Label.create!(creative: label_creative, owner: @user)
      Tag.create!(creative_id: child1.id, label: label)
      Tag.create!(creative_id: child2.id, label: label)

      # Filter: tagged AND progress = 100%
      result = FilterPipeline.new(
        user: @user,
        params: { tags: [ label.id ], min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: [ parent.id, child1.id, child2.id ])
      ).call

      # Only child1 matches both conditions
      assert_includes result.matched_ids, child1.id, "Child1 should be matched (tagged AND 100%)"
      refute_includes result.matched_ids, child2.id, "Child2 should not be matched (only 50%)"

      # Parent should be in allowed_ids as ancestor
      assert_includes result.allowed_ids, parent.id.to_s, "Parent should be in allowed_ids"
    end

    test "returns empty result when no matches" do
      parent = Creative.create!(user: @user, description: "Parent", progress: 0.0)

      result = FilterPipeline.new(
        user: @user,
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: parent.id)
      ).call

      assert result.matched_ids.empty?, "Should have no matches"
      assert result.allowed_ids.empty?, "Should have no allowed ids"
    end

    test "calculates progress map correctly" do
      parent = Creative.create!(user: @user, description: "Parent", progress: 0.5)
      child = Creative.create!(user: @user, parent: parent, description: "Child", progress: 1.0)

      # Note: closure_tree auto-updates parent progress from children average
      parent.reload

      result = FilterPipeline.new(
        user: @user,
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: [ parent.id, child.id ])
      ).call

      # parent is in allowed_ids (as ancestor) but not matched
      # parent's progress is auto-updated to child's average (1.0)
      assert_in_delta parent.progress, result.progress_map[parent.id.to_s], 0.01, "Parent progress should match DB value"
      assert_in_delta 1.0, result.progress_map[child.id.to_s], 0.01, "Child progress should be 1.0"
      assert_in_delta 1.0, result.overall_progress, 0.01, "Overall should be average of matched (only child)"
    end

    test "public share (user_id: nil) accessible by anonymous user" do
      other_user = users(:two)
      creative = Creative.create!(user: other_user, description: "Public creative", progress: 1.0)

      # Public share (user_id: nil)
      CreativeShare.create!(creative: creative, user: nil, permission: :read)

      result = FilterPipeline.new(
        user: nil,  # Anonymous user
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: creative.id)
      ).call

      assert_includes result.matched_ids, creative.id, "Public creative should be matched"
      assert_includes result.allowed_ids, creative.id.to_s, "Public creative should be in allowed_ids"
    end

    test "public share (user_id: nil) accessible by logged in user" do
      other_user = users(:two)
      creative = Creative.create!(user: other_user, description: "Public creative", progress: 1.0)

      # Public share (user_id: nil)
      CreativeShare.create!(creative: creative, user: nil, permission: :read)

      result = FilterPipeline.new(
        user: @user,  # Logged in user (not owner)
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: creative.id)
      ).call

      assert_includes result.matched_ids, creative.id, "Public creative should be matched"
      assert_includes result.allowed_ids, creative.id.to_s, "Public creative should be accessible to logged in user"
    end

    test "filters out creatives without permission" do
      other_user = users(:two)
      owned_creative = Creative.create!(user: @user, description: "Owned", progress: 1.0)
      shared_creative = Creative.create!(user: other_user, description: "Shared", progress: 1.0)
      unshared_creative = Creative.create!(user: other_user, description: "Unshared", progress: 1.0)

      # Share one creative with @user
      CreativeShare.create!(creative: shared_creative, user: @user, permission: :read)

      result = FilterPipeline.new(
        user: @user,
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: [ owned_creative.id, shared_creative.id, unshared_creative.id ])
      ).call

      assert_includes result.allowed_ids, owned_creative.id.to_s, "Owned creative should be allowed"
      assert_includes result.allowed_ids, shared_creative.id.to_s, "Shared creative should be allowed"
      refute_includes result.allowed_ids, unshared_creative.id.to_s, "Unshared creative should not be allowed"
    end

    test "anonymous user cannot access non-public creatives" do
      creative = Creative.create!(user: @user, description: "Private", progress: 1.0)
      # No public share

      result = FilterPipeline.new(
        user: nil,  # Anonymous user
        params: { min_progress: "1", max_progress: "1" },
        scope: Creative.where(id: creative.id)
      ).call

      assert_includes result.matched_ids, creative.id, "Creative matches the filter"
      refute_includes result.allowed_ids, creative.id.to_s, "Private creative should not be accessible to anonymous user"
    end
  end
end

require "test_helper"

module Creatives
  class FilterPipelineTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @shared_user = users(:two)
      @root = Creative.create!(user: @owner, description: "Root", progress: 0.5)
      @child1 = Creative.create!(user: @owner, description: "Child 1", progress: 1.0, parent: @root)
      @child2 = Creative.create!(user: @owner, description: "Child 2", progress: 0.0, parent: @root)
    end

    test "filter_by_permission returns only accessible creatives" do
      # Share root with user
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      scope = Creative.where(id: [ @root.id, @child1.id, @child2.id ])
      result = FilterPipeline.new(user: @shared_user, params: {}, scope: scope).call

      assert_includes result.allowed_ids, @root.id.to_s
      assert_includes result.allowed_ids, @child1.id.to_s
      assert_includes result.allowed_ids, @child2.id.to_s
    end

    test "filter_by_permission excludes unshared creatives" do
      other_creative = Creative.create!(user: @owner, description: "Other", progress: 0.0)

      # Only share root
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      scope = Creative.where(id: [ @root.id, other_creative.id ])
      result = FilterPipeline.new(user: @shared_user, params: {}, scope: scope).call

      assert_includes result.allowed_ids, @root.id.to_s
      refute_includes result.allowed_ids, other_creative.id.to_s
    end

    test "filter_by_permission includes owned creatives" do
      # No shares, but owner should see their creatives
      scope = Creative.where(id: [ @root.id, @child1.id ])
      result = FilterPipeline.new(user: @owner, params: {}, scope: scope).call

      assert_includes result.allowed_ids, @root.id.to_s
      assert_includes result.allowed_ids, @child1.id.to_s
    end

    test "resolve_ancestors includes parent creatives" do
      # Share only child, but parent should be included
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      scope = Creative.where(id: [ @child1.id ])
      result = FilterPipeline.new(user: @shared_user, params: { min_progress: "1", max_progress: "1" }, scope: scope).call

      # Child1 matches filter, root is its ancestor
      assert_includes result.allowed_ids, @child1.id.to_s
      assert_includes result.allowed_ids, @root.id.to_s  # ancestor included
    end

    test "progress filtering works with completed (min=1, max=1)" do
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      scope = Creative.where(id: [ @root.id, @child1.id, @child2.id ])
      result = FilterPipeline.new(user: @shared_user, params: { min_progress: "1", max_progress: "1" }, scope: scope).call

      assert_includes result.matched_ids, @child1.id  # progress = 1.0
      refute_includes result.matched_ids, @child2.id  # progress = 0.0
    end

    test "progress filtering works with incomplete (min=0, max=0.99)" do
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      scope = Creative.where(id: [ @root.id, @child1.id, @child2.id ])
      result = FilterPipeline.new(user: @shared_user, params: { min_progress: "0", max_progress: "0.99" }, scope: scope).call

      refute_includes result.matched_ids, @child1.id  # progress = 1.0
      assert_includes result.matched_ids, @child2.id  # progress = 0.0
      assert_includes result.matched_ids, @root.id    # progress = 0.5
    end

    test "empty result when no creatives match" do
      scope = Creative.none
      result = FilterPipeline.new(user: @shared_user, params: {}, scope: scope).call

      assert_empty result.matched_ids
      assert_empty result.allowed_ids
      assert_equal 0.0, result.overall_progress
    end

    test "calculates overall progress correctly" do
      CreativeShare.create!(creative: @root, user: @shared_user, permission: "read")

      scope = Creative.where(id: [ @child1.id, @child2.id ])
      result = FilterPipeline.new(user: @shared_user, params: {}, scope: scope).call

      # (1.0 + 0.0) / 2 = 0.5
      assert_equal 0.5, result.overall_progress
    end

    test "public share allows access without user" do
      CreativeShare.create!(creative: @root, user: nil, permission: "read")

      scope = Creative.where(id: [ @root.id, @child1.id ])
      result = FilterPipeline.new(user: nil, params: {}, scope: scope).call

      assert_includes result.allowed_ids, @root.id.to_s
      assert_includes result.allowed_ids, @child1.id.to_s
    end
  end
end

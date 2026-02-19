require "test_helper"

module Creatives
  class ReordererTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(
        email: "reorderer@example.com",
        password: "password123",
        name: "Reorderer",
        email_verified_at: Time.current,
        notifications_enabled: false
      )

      @root = Creative.create!(description: "Root", user: @user)
      @child_a = Creative.create!(description: "A", user: @user, parent: @root, sequence: 0)
      @child_b = Creative.create!(description: "B", user: @user, parent: @root, sequence: 1)
      @child_c = Creative.create!(description: "C", user: @user, parent: @root, sequence: 2)
      @child_d = Creative.create!(description: "D", user: @user, parent: @root, sequence: 3)

      @reorderer = Reorderer.new(user: @user)
    end

    test "reorder_multiple inserts selected creatives as siblings in original order" do
      @reorderer.reorder_multiple(
        dragged_ids: [ @child_c.id, @child_a.id ],
        target_id: @child_b.id,
        direction: "up"
      )

      order = @root.reload.children.order(:sequence).map { |creative| ActionController::Base.helpers.strip_tags(creative.description) }
      assert_equal [ "C", "A", "B", "D" ], order
    end

    test "reorder_multiple appends creatives as children preserving order" do
      new_parent = Creative.create!(description: "Parent", user: @user)

      @reorderer.reorder_multiple(
        dragged_ids: [ @child_a.id, @child_b.id ],
        target_id: new_parent.id,
        direction: "child"
      )

      root_order = @root.reload.children.order(:sequence).map { |creative| ActionController::Base.helpers.strip_tags(creative.description) }
      assert_equal [ "C", "D" ], root_order

      child_order = new_parent.reload.children.order(:sequence).map { |creative| ActionController::Base.helpers.strip_tags(creative.description) }
      assert_equal [ "A", "B" ], child_order
    end

    test "reorder_multiple raises when target is within selection" do
      assert_raises(Reorderer::Error) do
        @reorderer.reorder_multiple(
          dragged_ids: [ @child_a.id, @child_b.id ],
          target_id: @child_a.id,
          direction: "down"
        )
      end
    end

    test "reorder_multiple raises when target is descendant of dragged creative" do
      descendant = Creative.create!(description: "Child", user: @user, parent: @child_a)

      assert_raises(Reorderer::Error) do
        @reorderer.reorder_multiple(
          dragged_ids: [ @child_a.id, @child_b.id ],
          target_id: descendant.id,
          direction: "up"
        )
      end
    end

    test "reorder raises when dragged creative is owned by another user" do
      other_user = User.create!(
        email: "other@example.com",
        password: "password123",
        name: "Other",
        email_verified_at: Time.current,
        notifications_enabled: false
      )
      other_creative = Creative.create!(description: "Other's", user: other_user)

      assert_raises(Reorderer::Error) do
        @reorderer.reorder(
          dragged_id: other_creative.id,
          target_id: @root.id,
          direction: "child"
        )
      end
    end

    test "reorder raises when target creative is owned by another user" do
      other_user = User.create!(
        email: "other2@example.com",
        password: "password123",
        name: "Other2",
        email_verified_at: Time.current,
        notifications_enabled: false
      )
      other_creative = Creative.create!(description: "Other's", user: other_user)

      assert_raises(Reorderer::Error) do
        @reorderer.reorder(
          dragged_id: @child_a.id,
          target_id: other_creative.id,
          direction: "child"
        )
      end
    end

    test "reorder allows moving linked creative owned by user" do
      other_user = User.create!(
        email: "other3@example.com",
        password: "password123",
        name: "Other3",
        email_verified_at: Time.current,
        notifications_enabled: false
      )
      origin_creative = Creative.create!(description: "Origin", user: other_user)
      linked = Creative.create!(origin_id: origin_creative.id, user: @user)

      @reorderer.reorder(
        dragged_id: linked.id,
        target_id: @root.id,
        direction: "child"
      )

      assert_equal @root.id, linked.reload.parent_id
    end

    test "reorder_multiple raises when any dragged creative is owned by another user" do
      other_user = User.create!(
        email: "other4@example.com",
        password: "password123",
        name: "Other4",
        email_verified_at: Time.current,
        notifications_enabled: false
      )
      other_creative = Creative.create!(description: "Other's", user: other_user)

      assert_raises(Reorderer::Error) do
        @reorderer.reorder_multiple(
          dragged_ids: [ @child_a.id, other_creative.id ],
          target_id: @child_b.id,
          direction: "up"
        )
      end
    end
  end
end

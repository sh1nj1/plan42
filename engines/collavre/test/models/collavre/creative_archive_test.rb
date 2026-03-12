# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeArchiveTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user

      @parent = Creative.create!(description: "Parent", user: @user, progress: 0)
      @child1 = Creative.create!(description: "Child 1", user: @user, parent: @parent, progress: 1.0)
      @child2 = Creative.create!(description: "Child 2", user: @user, parent: @parent, progress: 0.5)
      @grandchild = Creative.create!(description: "Grandchild", user: @user, parent: @child1, progress: 1.0)
    end

    test "active scope returns non-archived creatives" do
      @child1.archive!
      active = Creative.active.where(parent: @parent)
      assert_includes active, @child2
      assert_not_includes active, @child1
    end

    test "archived scope returns archived creatives" do
      @child1.archive!
      archived = Creative.archived
      assert_includes archived, @child1
      assert_includes archived, @grandchild
    end

    test "archive! sets archived_at on self and descendants" do
      @child1.archive!

      @child1.reload
      @grandchild.reload
      assert @child1.archived?
      assert @grandchild.archived?
      assert_not @child2.archived?
    end

    test "unarchive! clears archived_at on self and descendants" do
      @child1.archive!
      @child1.unarchive!

      @child1.reload
      @grandchild.reload
      assert_not @child1.archived?
      assert_not @grandchild.archived?
    end

    test "archive! updates parent progress excluding archived child" do
      # Before archive: parent progress = (1.0 + 0.5) / 2 = 0.75
      @parent.reload
      assert_in_delta 0.75, @parent.progress, 0.01

      @child1.archive!
      @parent.reload

      # After archive: parent progress = 0.5 / 1 = 0.5 (only child2 counts)
      assert_in_delta 0.5, @parent.progress, 0.01
    end

    test "unarchive! recalculates parent progress including restored child" do
      @child1.archive!
      @parent.reload
      assert_in_delta 0.5, @parent.progress, 0.01

      @child1.unarchive!
      @parent.reload

      # After unarchive: parent progress = (1.0 + 0.5) / 2 = 0.75
      assert_in_delta 0.75, @parent.progress, 0.01
    end
  end
end

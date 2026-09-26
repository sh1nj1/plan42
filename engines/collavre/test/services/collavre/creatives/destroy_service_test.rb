# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class DestroyServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @root = Creative.create!(description: "Root", user: @user)
        @target = Creative.create!(description: "Target", user: @user, parent: @root)
        @child = Creative.create!(description: "Child", user: @user, parent: @target)
      end

      test "deletes descendants when requested" do
        grandchild = Creative.create!(description: "Grandchild", user: @user, parent: @child)

        DestroyService.new(creative: @target, user: @user, delete_with_children: true).call

        assert_not Creative.exists?(@target.id)
        assert_not Creative.exists?(@child.id)
        assert_not Creative.exists?(grandchild.id)
      end

      test "reparents children by default" do
        DestroyService.new(creative: @target, user: @user).call

        assert_not Creative.exists?(@target.id)
        assert_equal @root, @child.reload.parent
      end

      test "does not cascade into the origin tree of a linked creative" do
        link = Creative.create!(user: @user, parent: @root, origin: @target)
        nested_link = Creative.create!(user: @user, parent: @child, origin: @root)

        DestroyService.new(creative: link, user: @user, delete_with_children: true).call

        assert_not Creative.exists?(link.id)
        assert Creative.exists?(@target.id)
        assert Creative.exists?(@child.id)
        assert Creative.exists?(nested_link.id)
      end

      test "does not cascade through linked descendants into their origin" do
        other = Creative.create!(description: "Other", user: @user)
        other_child = Creative.create!(description: "Other child", user: @user, parent: other)
        link = Creative.create!(user: @user, parent: @child, origin: other)

        DestroyService.new(creative: @target, user: @user, delete_with_children: true).call

        assert_not Creative.exists?(link.id)
        assert Creative.exists?(other.id)
        assert Creative.exists?(other_child.id)
      end
    end
  end
end

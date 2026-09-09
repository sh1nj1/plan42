# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeAiWritePolicyTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @root = Creative.create!(description: "Root", user: @user)
      @child = Creative.create!(description: "Child", user: @user, parent: @root)
    end

    test "defaults to auto" do
      assert_equal "auto", @child.effective_ai_write_policy
      assert_not @child.ai_write_review?
    end

    test "inherits the nearest valid policy from ancestors" do
      @root.update!(data: @root.data.merge("ai_write_policy" => "review"))
      assert_equal "review", @child.effective_ai_write_policy

      @child.update!(data: @child.data.merge("ai_write_policy" => "auto"))
      assert_equal "auto", @child.effective_ai_write_policy
    end

    test "ignores invalid policy values" do
      @root.update!(data: @root.data.merge("ai_write_policy" => "sometimes"))

      assert_equal "auto", @child.effective_ai_write_policy
    end
  end
end

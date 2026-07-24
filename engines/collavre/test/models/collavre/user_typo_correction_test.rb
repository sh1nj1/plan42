# frozen_string_literal: true

require "test_helper"

module Collavre
  # The typo_correction_threshold column is NOT NULL. Clearing the profile field
  # (or a crafted PATCH) casts the param to nil; without a validation the save
  # would raise a DB NOT NULL error instead of re-rendering the form.
  class UserTypoCorrectionTest < ActiveSupport::TestCase
    setup { @user = users(:one) }

    test "rejects a nil threshold instead of hitting the NOT NULL column" do
      @user.typo_correction_threshold = nil
      assert_not @user.valid?
      assert_includes @user.errors.attribute_names, :typo_correction_threshold
    end

    test "rejects an out-of-range threshold" do
      @user.typo_correction_threshold = 150
      assert_not @user.valid?
      @user.typo_correction_threshold = -1
      assert_not @user.valid?
    end

    test "rejects a non-integer threshold" do
      @user.typo_correction_threshold = 50.5
      assert_not @user.valid?
    end

    test "accepts the inclusive 0..100 bounds" do
      @user.typo_correction_threshold = 0
      assert @user.valid?, @user.errors.full_messages.to_sentence
      @user.typo_correction_threshold = 100
      assert @user.valid?, @user.errors.full_messages.to_sentence
    end
  end
end

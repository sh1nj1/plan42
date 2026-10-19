# frozen_string_literal: true

require "test_helper"

module Collavre
  class SystemSettingScreeningTest < ActiveSupport::TestCase
    test "screening is off with Jev defaults until configured" do
      assert_not SystemSetting.screening_enabled?
      assert_equal "jev-latest", SystemSetting.screening_model
      assert_equal 0.5, SystemSetting.screening_threshold
      assert_equal 0.9, SystemSetting.screening_block_threshold
    end

    test "configured values are read and invalid probabilities fall back" do
      SystemSetting.create!(key: "screening_enabled", value: "true")
      SystemSetting.create!(key: "screening_model", value: "jev-preview")
      SystemSetting.create!(key: "screening_threshold", value: "0.3")
      SystemSetting.create!(key: "screening_block_threshold", value: "1.5")
      assert SystemSetting.screening_enabled?
      assert_equal "jev-preview", SystemSetting.screening_model
      assert_equal 0.3, SystemSetting.screening_threshold
      assert_equal 0.9, SystemSetting.screening_block_threshold
    end

    test "the block threshold never sits below the flag threshold" do
      SystemSetting.create!(key: "screening_threshold", value: "0.8")
      SystemSetting.create!(key: "screening_block_threshold", value: "0.6")
      assert_equal 0.8, SystemSetting.screening_block_threshold
      SystemSetting.find_by!(key: "screening_threshold").update!(value: "abc")
      assert_equal 0.5, SystemSetting.screening_threshold
    end
  end
end

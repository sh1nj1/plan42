# frozen_string_literal: true

require "test_helper"

module Collavre
  class IntegrationSettingTest < ActiveSupport::TestCase
    test "encrypts value" do
      setting = IntegrationSetting.create!(key: "slack_client_id", value: "xoxb-secret", category: "slack")
      raw = IntegrationSetting.connection.select_value(
        "SELECT value FROM integration_settings WHERE id = #{setting.id}"
      )
      assert_not_equal "xoxb-secret", raw
      assert_equal "xoxb-secret", setting.reload.value
    end

    test "requires unique key" do
      IntegrationSetting.create!(key: "slack_client_id", value: "a", category: "slack")
      dup = IntegrationSetting.new(key: "slack_client_id", value: "b", category: "slack")
      assert_not dup.valid?
    end

    test "clears cache on commit" do
      Rails.cache.write(IntegrationSetting.cache_key_for("slack_client_id"), "cached")
      IntegrationSetting.create!(key: "slack_client_id", value: "new", category: "slack")
      assert_nil Rails.cache.read(IntegrationSetting.cache_key_for("slack_client_id"))
    end
  end
end

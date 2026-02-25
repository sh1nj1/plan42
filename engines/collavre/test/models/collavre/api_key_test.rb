# frozen_string_literal: true

require "test_helper"

module Collavre
  class ApiKeyTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
    end

    test "generates token with correct prefix" do
      token = ApiKey.generate_token
      assert token.start_with?("sk-collavre-")
      assert_equal 60, token.length # "sk-collavre-" (12) + 48 hex chars
    end

    test "creates api key with token" do
      api_key, token = ApiKey.create_with_token!(user: @user, name: "Test Key")
      assert api_key.persisted?
      assert_equal "Test Key", api_key.name
      assert token.start_with?("sk-collavre-")
      assert_equal token[0, 8], api_key.token_prefix
    end

    test "finds api key by token" do
      _api_key, token = ApiKey.create_with_token!(user: @user, name: "Lookup Key")
      found = ApiKey.find_by_token(token)
      assert_not_nil found
      assert_equal "Lookup Key", found.name
    end

    test "does not find expired key" do
      _api_key, token = ApiKey.create_with_token!(user: @user, name: "Expired", expires_at: 1.day.ago)
      found = ApiKey.find_by_token(token)
      assert_nil found
    end

    test "returns nil for invalid token" do
      assert_nil ApiKey.find_by_token("invalid-token")
      assert_nil ApiKey.find_by_token(nil)
      assert_nil ApiKey.find_by_token("")
    end
  end
end

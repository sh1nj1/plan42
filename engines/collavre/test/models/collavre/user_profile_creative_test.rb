require "test_helper"

module Collavre
  class UserProfileCreativeTest < ActiveSupport::TestCase
    test "human user gets a profile creative on create" do
      u = Collavre::User.create!(name: "Human", email: "h@example.com", password: "password123")
      assert_equal "profile", u.profile_creative.data["kind"]
    end

    test "AI agent also gets a profile creative on create" do
      a = Collavre::User.create!(name: "Bot", email: "bot@example.com", password: "password123", llm_vendor: "google")
      assert a.ai_user?
      assert_equal "profile", a.profile_creative.data["kind"]
    end
  end
end

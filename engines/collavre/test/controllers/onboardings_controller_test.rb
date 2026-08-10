# frozen_string_literal: true

require "test_helper"

module Collavre
  class OnboardingsControllerTest < ActionDispatch::IntegrationTest
    test "first workspace entry seeds once, opens the onboarding chat once, and exposes runner state" do
      user = User.create!(name: "First visit", email: "first-visit@example.com", password: "password")
      sign_in_as(user, password: "password")

      get creatives_path

      assert_response :success
      session = Onboarding::Session.for_user(user.reload)
      assert session
      assert_includes response.body, "onboarding-card"
      refute session.data.key?("chat_autoopen_pending")

      get onboarding_path, as: :json
      assert_response :success
      assert_equal "tree_node", response.parsed_body.fetch("current_step")

      get creatives_path
      assert_response :success
      refute_includes response.body, "data-creative-id=\"#{session.root.id}\""
    end
  end
end

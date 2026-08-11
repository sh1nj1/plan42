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
      assert_equal session.root.id, response.parsed_body.fetch("anchor_key")

      get creatives_path
      assert_response :success
      refute_includes response.body, "data-creative-id=\"#{session.root.id}\""
      assert_includes response.body, "onboarding-card"
    end

    test "advances and completes onboarding through the namespaced services" do
      user = User.create!(name: "Learner", email: "onboarding-actions@example.com", password: "password")
      sign_in_as(user, password: "password")
      session = Onboarding::Seeder.new(user: user).call

      post advance_onboarding_path, as: :json

      assert_response :success
      assert_equal "progress", response.parsed_body.fetch("current_step")
      assert_equal session.practice_creative_ids.first, response.parsed_body.fetch("anchor_key")
      assert_equal creatives_path(id: session.root), response.parsed_body.fetch("navigation_path")

      post complete_onboarding_path, as: :json

      assert_response :success
      assert user.reload.onboarding_completed_at?
      assert_nil Onboarding::Session.for_user(user)
      assert_nil Creative.find_by(id: session.root.id)
    end

    test "reset seeds onboarding even when the user already has a workspace" do
      user = User.create!(name: "Returning learner", email: "onboarding-reset@example.com", password: "password")
      Creative.create!(user: user, description: "Existing workspace")
      sign_in_as(user, password: "password")

      post reset_onboarding_path

      assert_redirected_to creatives_path
      session = Onboarding::Session.for_user(user.reload)
      assert session
      assert_equal 2, session.root.children.count
      assert user.onboarding_seeded_at?
      assert_nil user.onboarding_completed_at
    end

    test "reset removes practice items orphaned by a deleted onboarding root" do
      user = User.create!(name: "Reset deleted root", email: "reset-deleted-root@example.com", password: "password")
      sign_in_as(user, password: "password")
      previous_session = Onboarding::Seeder.new(user: user).call
      orphaned_practice_ids = previous_session.practice_creative_ids
      Creatives::DestroyService.new(creative: previous_session.root, user: user).call

      post reset_onboarding_path

      assert_redirected_to creatives_path
      assert_empty user.creatives.where(id: orphaned_practice_ids)
      assert Onboarding::Session.for_user(user.reload)
    end

    test "reset enables workspace mode so the runner can be displayed" do
      user = User.create!(
        name: "Workspace disabled learner", email: "workspace-disabled-onboarding@example.com", password: "password",
        creative_workspace_enabled: false
      )
      sign_in_as(user, password: "password")

      post reset_onboarding_path

      assert_redirected_to creatives_path
      assert_predicate user.reload, :creative_workspace_enabled?
      assert Onboarding::Session.for_user(user)
    end

    test "description editing advances when the inline form also submits unchanged progress" do
      user = User.create!(name: "Editor", email: "onboarding-editor@example.com", password: "password")
      sign_in_as(user, password: "password")
      session = Onboarding::Seeder.new(user: user).call
      first, second = session.practice_creatives.order(:id)

      post advance_onboarding_path, as: :json
      patch creative_path(first), params: { creative: { progress: 1.0 } }, as: :json

      assert_response :success
      assert_equal "editor", Onboarding::Session.for_user(user).data.fetch("current_step")

      patch creative_path(second), params: {
        creative: { description: "Updated practice item", progress: second.progress }
      }, as: :json

      assert_response :success
      assert_equal "Updated practice item", second.reload.description
      assert_equal "comment", Onboarding::Session.for_user(user).data.fetch("current_step")
    end
  end
end

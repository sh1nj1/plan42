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
      assert_select "#comments-popup[data-creative-id='#{session.root.id}']", count: 1
      assert_select "#comments-popup[data-auto-open='true']", count: 1
      assert_select "[data-onboarding-card-target='chatIcon']", count: 0
      refute session.data.key?("chat_autoopen_pending")

      get onboarding_path, as: :json
      assert_response :success
      assert_equal session.session_id, response.parsed_body.fetch("session_id")
      assert_equal "progress", response.parsed_body.fetch("current_step")
      assert_equal "tree.add", response.parsed_body.fetch("anchor")
      assert_equal session.practice_creative_ids.first, response.parsed_body.fetch("anchor_key")
      assert_equal "progress", response.parsed_body.dig("instruction_control", "type")
      assert_equal I18n.t("collavre.onboarding.steps.progress.control"), response.parsed_body.dig("instruction_control", "label")

      get creatives_path
      assert_response :success
      refute_includes response.body, "data-creative-id=\"#{session.root.id}\""
      assert_select "#comments-popup #comments-list .onboarding-card[data-onboarding-card-session-id-value='#{session.session_id}']", count: 1
    end

    test "speculative workspace requests do not consume onboarding auto-open state" do
      user = User.create!(name: "Prefetched visit", email: "prefetched-onboarding@example.com", password: "password")
      sign_in_as(user, password: "password")

      get creatives_path, headers: { "X-Sec-Purpose" => "prefetch" }
      assert_response :success
      assert_nil Onboarding::Session.for_user(user.reload)

      head creatives_path
      assert_response :success
      assert_nil Onboarding::Session.for_user(user.reload)

      get creatives_path
      assert_response :success
      session = Onboarding::Session.for_user(user.reload)
      assert session
      refute session.data.key?("chat_autoopen_pending")
      assert_select "#comments-popup[data-creative-id='#{session.root.id}']", count: 1
    end

    test "advances and completes onboarding through the namespaced services" do
      user = User.create!(name: "Learner", email: "onboarding-actions@example.com", password: "password")
      sign_in_as(user, password: "password")
      session = Onboarding::Seeder.new(user: user).call

      post advance_onboarding_path, params: { session_id: session.session_id }, as: :json

      assert_response :success
      assert_equal "progress", response.parsed_body.fetch("current_step")
      assert_equal session.practice_creative_ids.first, response.parsed_body.fetch("anchor_key")
      assert_equal creatives_path(id: session.root, open_comments: true), response.parsed_body.fetch("navigation_path")

      post complete_onboarding_path, params: { session_id: session.session_id }, as: :json

      assert_response :success
      assert_equal({ "success" => true }, response.parsed_body)
      assert user.reload.onboarding_completed_at?
      assert_nil Onboarding::Session.for_user(user)
      assert_nil Creative.find_by(id: session.root.id)
    end

    test "records an item added to the onboarding root before it is completed" do
      user = User.create!(name: "Item adder", email: "onboarding-item-adder@example.com", password: "password")
      sign_in_as(user, password: "password")
      session = Onboarding::Seeder.new(user: user).call

      post creatives_path, params: { creative: { description: "New practice item", parent_id: session.root.id } }, as: :json

      assert_response :success
      added_id = response.parsed_body.fetch("id")
      assert_equal added_id, Onboarding::Session.for_user(user.reload).added_practice_creative_id

      get onboarding_path, as: :json

      assert_equal added_id, response.parsed_body.fetch("anchor_key")
    end

    test "returns to the add instruction when the added practice item is moved" do
      user = User.create!(name: "Moved item adder", email: "moved-item-adder@example.com", password: "password")
      sign_in_as(user, password: "password")
      session = Onboarding::Seeder.new(user: user).call
      added = Creative.create!(user: user, parent: session.root, description: "New practice item")
      Onboarding::ProgressTracker.record(user: user, event: :creative_created, creative: added)
      destination = Creative.create!(user: user, description: "Moved item destination")
      added.update!(parent: destination)

      get onboarding_path, as: :json

      assert_response :success
      assert_equal "tree.add", response.parsed_body.fetch("anchor")
      assert_equal "progress", response.parsed_body.dig("instruction_control", "type")
      assert_nil Onboarding::Session.for_user(user.reload).added_practice_creative_id
    end

    test "rejects stale card mutations after onboarding is reset in another tab" do
      user = User.create!(name: "Stale learner", email: "stale-onboarding-actions@example.com", password: "password")
      sign_in_as(user, password: "password")
      stale_session = Onboarding::Seeder.new(user: user).call

      post reset_onboarding_path
      replacement_session = Onboarding::Session.for_user(user.reload)
      user.update!(locale: "ko")

      post advance_onboarding_path, params: { session_id: stale_session.session_id }, as: :json

      assert_response :conflict
      assert_equal I18n.t("collavre.onboarding.errors.stale_session", locale: :ko), response.parsed_body.fetch("error")
      assert_equal :progress, Onboarding::Session.for_user(user.reload).current_step.key
      assert_equal replacement_session.session_id, Onboarding::Session.for_user(user).session_id

      post complete_onboarding_path, params: { session_id: stale_session.session_id }, as: :json

      assert_response :conflict
      assert Creative.exists?(replacement_session.root.id)
      assert_nil user.reload.onboarding_completed_at
    end

    test "does not complete a replacement session when a conditional completion receives a stale session id" do
      user = User.create!(name: "Conditional finisher", email: "conditional-onboarding@example.com", password: "password")
      sign_in_as(user, password: "password")
      stale_session = Onboarding::Seeder.new(user: user).call

      post reset_onboarding_path
      replacement_session = Onboarding::Session.for_user(user.reload)

      refute Onboarding::CompletionService.new(user: user).call(session_id: stale_session.session_id)

      assert Creative.exists?(replacement_session.root.id)
      assert_equal replacement_session.session_id, Onboarding::Session.for_user(user.reload).session_id
      assert_nil user.onboarding_completed_at
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

    test "reset defers old session cleanup while its agent reply is pending" do
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs

      user = User.create!(name: "Reset awaiting reply", email: "reset-awaiting-reply@example.com", password: "password")
      agent = User.create!(name: "Reset reply helper", email: "reset-reply-helper@example.com", password: "password",
                           llm_vendor: "openai", searchable: true)
      sign_in_as(user, password: "password")
      previous_session = Onboarding::Seeder.new(user: user).call
      creative = previous_session.practice_creatives.second
      comment = Comment.create!(creative: creative, user: user, content: "@Reset reply helper: Please help")
      task = Task.create!(name: "Pending reply", status: "running", trigger_event_name: "comment_created",
                          trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent, creative: creative)

      assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, previous_session.session_id ]) do
        post reset_onboarding_path
      end

      assert_redirected_to creatives_path
      assert Creative.exists?(creative.id)
      assert Comment.exists?(comment.id)
      new_session = Onboarding::Session.for_user(user.reload)
      assert new_session
      assert_not_equal previous_session.session_id, new_session.session_id

      task.update!(status: "done")
      OnboardingCleanupJob.perform_now(user.id, previous_session.session_id)

      refute Creative.exists?(creative.id)
      assert Creative.exists?(new_session.root.id)
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    test "reset cleans a retired session when its agent turn settles after the retry window" do
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs

      user = User.create!(name: "Retired session cleanup", email: "retired-session-cleanup@example.com", password: "password")
      agent = User.create!(name: "Retired session helper", email: "retired-session-helper@example.com", password: "password",
                           llm_vendor: "openai", searchable: true)
      sign_in_as(user, password: "password")
      previous_session = Onboarding::Seeder.new(user: user).call
      creative = previous_session.practice_creatives.second
      comment = Comment.create!(creative: creative, user: user, content: "@Retired session helper: Please help")
      task = Task.create!(name: "Pending retired reply", status: "pending_approval", trigger_event_name: "comment_created",
                          trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent, creative: creative)

      post reset_onboarding_path
      clear_enqueued_jobs
      OnboardingCleanupJob.perform_now(user.id, previous_session.session_id, OnboardingCleanupJob::RETRY_DELAYS.length)

      assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, previous_session.session_id ]) do
        task.update!(status: "done")
      end

      OnboardingCleanupJob.perform_now(user.id, previous_session.session_id)
      refute Creative.exists?(creative.id)
      assert Onboarding::Session.for_user(user.reload)
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
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
      _first, second = session.practice_creatives.order(:id)

      post advance_onboarding_path, params: { session_id: session.session_id }, as: :json
      added = Creative.create!(user: user, parent: session.root, description: "Added practice item")
      Onboarding::ProgressTracker.record(user: user, event: :creative_created, creative: added)
      patch creative_path(added), params: { creative: { progress: 1.0 } }, as: :json

      assert_response :success
      assert_equal "editor", Onboarding::Session.for_user(user).data.fetch("current_step")

      patch creative_path(second), params: {
        creative: { description: "Updated practice item", progress: second.progress }
      }, as: :json

      assert_response :success
      assert_equal "Updated practice item", second.reload.description
      assert_equal "comment", Onboarding::Session.for_user(user).data.fetch("current_step")

      get onboarding_path, as: :json

      assert_response :success
      assert_equal creatives_path(id: second, open_comments: true), response.parsed_body.fetch("navigation_path")
    end
  end
end

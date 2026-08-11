# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class SeederTest < ActiveSupport::TestCase
      test "creates one root and two practice children once" do
        user = User.create!(name: "New learner", email: "learner@example.com", password: "password")

        session = Seeder.new(user: user).call

        assert_equal "first_steps", session.data["scenario_key"]
        assert_equal 2, session.root.children.count
        assert user.reload.onboarding_seeded_at?
        assert_equal session.root, Seeder.new(user: user).call.root
      end

      test "shares the practice tree with an available AI agent" do
        user = User.create!(name: "Learner with agent", email: "learner-with-agent@example.com", password: "password")
        agent = User.create!(
          name: "Helpful agent", email: "helpful-agent@example.com", password: "password",
          llm_vendor: "openai", searchable: true
        )

        session = Seeder.new(user: user).call

        assert_equal "feedback", CreativeShare.find_by!(creative: session.root, user: agent).permission
        assert session.practice_creatives.all? { |creative| creative.has_permission?(agent, :feedback) }
        assert_equal true, session.data["agent_mention_enabled"]
      end

      test "omits the agent mention step when no agent is available" do
        user = User.create!(name: "Core-only learner", email: "core-only-learner@example.com", password: "password")

        User.stub(:accessible_ai_agents_for, User.none) do
          session = Seeder.new(user: user).call

          assert_equal false, session.data["agent_mention_enabled"]
          refute_includes session.scenario.steps.map(&:key), :mention
        end
      end

      test "resolves a practice creative to its scenario root" do
        user = User.create!(name: "Practice learner", email: "practice-learner@example.com", password: "password")
        seeded_session = Seeder.new(user: user).call

        session = Session.for_creative(seeded_session.practice_creatives.first)

        assert_equal seeded_session.root, session.root
        assert_equal :first_steps, session.scenario.key
      end

      test "builds progress navigation inside a mounted engine" do
        user = User.create!(name: "Mounted learner", email: "mounted-onboarding@example.com", password: "password")
        session = Seeder.new(user: user).call
        progress_step = session.scenario.steps.find { |step| step.key == :progress }

        assert_equal "/collavre/creatives?id=#{session.root.id}",
                     session.navigation_path(progress_step, script_name: "/collavre")
      end

      test "does not add onboarding to an existing workspace" do
        user = users(:one)

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
      end

      test "force seeds onboarding alongside an existing workspace" do
        user = users(:one)

        session = Seeder.new(user: user, force: true).call

        assert_equal "first_steps", session.data["scenario_key"]
        assert user.reload.onboarding_seeded_at?
      end

      test "marks a deleted onboarding session complete without reseeding it" do
        user = User.create!(name: "Deleted onboarding", email: "deleted-onboarding@example.com", password: "password")
        session = Seeder.new(user: user).call
        practice_ids = session.practice_creatives.map(&:id)
        Creatives::DestroyService.new(creative: session.root, user: user).call

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_nil Session.for_user(user)
        assert_empty user.creatives.where(id: practice_ids)
      end

      test "cleans up and completes a session with a deleted practice creative" do
        user = User.create!(name: "Damaged onboarding", email: "damaged-onboarding@example.com", password: "password")
        session = Seeder.new(user: user).call
        remaining_practice = session.practice_creatives.second

        Creatives::DestroyService.new(creative: session.practice_creatives.first, user: user).call

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_nil Session.for_user(user)
        refute Creative.exists?(session.root.id)
        refute Creative.exists?(remaining_practice.id)
      end
    end
  end
end

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

      test "resolves a practice creative to its scenario root" do
        user = User.create!(name: "Practice learner", email: "practice-learner@example.com", password: "password")
        seeded_session = Seeder.new(user: user).call

        session = Session.for_creative(seeded_session.practice_creatives.first)

        assert_equal seeded_session.root, session.root
        assert_equal :first_steps, session.scenario.key
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
    end
  end
end

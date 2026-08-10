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

      test "does not add onboarding to an existing workspace" do
        user = users(:one)

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
      end
    end
  end
end

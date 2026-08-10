# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class CompletionServiceTest < ActiveSupport::TestCase
      test "removes every item carrying the session id even after a practice item moves" do
        user = User.create!(name: "Finisher", email: "finisher@example.com", password: "password")
        session = Seeder.new(user: user).call
        moved = session.practice_creatives.first
        moved.update!(parent: nil)

        CompletionService.new(user: user).call

        assert_empty user.creatives.where(id: [ session.root.id, moved.id ])
        assert user.reload.onboarding_completed_at?
      end
    end
  end
end

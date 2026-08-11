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

      test "removes orphaned practice items after their onboarding root is deleted" do
        user = User.create!(name: "Deleted root finisher", email: "deleted-root-finisher@example.com", password: "password")
        session = Seeder.new(user: user).call
        practice_ids = session.practice_creatives.map(&:id)
        Creatives::DestroyService.new(creative: session.root, user: user).call

        CompletionService.new(user: user).call

        assert_empty user.creatives.where(id: practice_ids)
        assert user.reload.onboarding_completed_at?
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class PinRejectionTest < ActiveSupport::TestCase
      setup do
        @agent = Collavre::User.create!(name: "Worker", email: "worker-#{SecureRandom.hex(4)}@test.test",
                                        password: "password123", llm_vendor: "google")
      end

      test "a missing-permission rejection tells the caller to share the creative" do
        message = PinRejection.message(@agent, :no_creative_access)

        assert_includes message, "Worker"
        assert_includes message, "Share the creative"
      end

      # Sharing cannot fix a session agent, so the advice must not mention it.
      test "a session-agent rejection does not send the caller after a share" do
        message = PinRejection.message(@agent, :session_agent_outside_session_topic)

        assert_includes message, "session topic"
        assert_not_includes message, "Share the creative"
      end
    end
  end
end

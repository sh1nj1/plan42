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

      test "chat capability rejection uses the caller locale" do
        { en: "Worker does not support chat and cannot be assigned as primary agent.",
          ko: "Worker은(는) 채팅을 지원하지 않아 Primary Agent로 지정할 수 없습니다." }.each do |locale, expected|
          I18n.with_locale(locale) do
            assert_equal expected, PinRejection.message(@agent, :chat_not_supported)
          end
        end
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

require "test_helper"

module Collavre
  class TypoCorrectionsControllerTest < ActionDispatch::IntegrationTest
    # Raises if #correct is ever reached, so the gating/size/rate guards can
    # prove they short-circuit *before* spending an LLM call.
    class RaisingCorrector
      def correct(_text)
        raise "TypoCorrector#correct must not be reached when the request is gated"
      end
    end

    class StubCorrector
      def correct(_text)
        [ { "original" => "teh", "suggestion" => "the", "confidence" => 0.9, "offset" => 0 } ]
      end
    end

    setup do
      Rails.cache.clear
      @user = User.create!(email: "typo_user@example.com", password: TEST_PASSWORD,
                           name: "Typo User", email_verified_at: Time.current)
      sign_in_as(@user)
    end

    test "runs the corrector and echoes the threshold on an enabled request" do
      TypoCorrector.stub(:new, StubCorrector.new) do
        post collavre.typo_corrections_path,
             params: { text: "teh", device: "soft_keyboard", location: "chat" }, as: :json
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 1, body["edits"].size
      assert_equal @user.typo_correction_threshold, body["threshold"]
    end

    test "skips the LLM for a disabled typing device (physical keyboard default-off)" do
      TypoCorrector.stub(:new, RaisingCorrector.new) do
        post collavre.typo_corrections_path,
             params: { text: "teh", device: "physical_keyboard", location: "chat" }, as: :json
      end
      assert_response :success
      assert_empty JSON.parse(response.body)["edits"]
    end

    test "skips the LLM for oversized input without erroring" do
      TypoCorrector.stub(:new, RaisingCorrector.new) do
        post collavre.typo_corrections_path,
             params: { text: "a" * (TypoCorrectionsController::MAX_TEXT_LENGTH + 1),
                       device: "soft_keyboard", location: "chat" }, as: :json
      end
      assert_response :success
      assert_empty JSON.parse(response.body)["edits"]
    end

    test "returns 429 once the per-user rate limit is exceeded" do
      Rails.cache.write("rate_limit:typo_correction:#{@user.id}",
                        TypoCorrectionsController::RATE_LIMIT, expires_in: 1.minute)
      TypoCorrector.stub(:new, StubCorrector.new) do
        post collavre.typo_corrections_path,
             params: { text: "teh", device: "soft_keyboard", location: "chat" }, as: :json
      end
      assert_response :too_many_requests
    end
  end
end

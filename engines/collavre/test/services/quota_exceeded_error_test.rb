require "test_helper"

class QuotaExceededErrorTest < ActiveSupport::TestCase
  test "accepts delta seconds and HTTP dates regardless of header case" do
    freeze_time do
      [ [ "Retry-After", "120" ], [ "retry-after", 2.minutes.from_now.httpdate ] ].each do |key, value|
        assert_equal 2.minutes.from_now, classify(headers: { key => value }).reset_at
      end
    end
  end

  test "missing malformed past and unreasonable reset times use bounded fallback" do
    [ nil, "", "-1", "0", "tomorrow", "1.5", "9" * 200, 1.day.ago.httpdate, (15.days.to_i).to_s ].each do |value|
      assert_nil classify(headers: { "Retry-After" => value }).reset_at
    end
  end

  test "recognizes the actual proxy SSE envelope with rewritten HTTP 400" do
    assert_instance_of Collavre::Quota::ExceededError, classify(status: 400)
  end

  test "does not confuse rate limits billing or unstructured errors with session quota" do
    assert_nil classify(code: "rate_limit_exceeded")
    assert_nil classify(message: "Please check billing and credit balance")
    assert_nil Collavre::Quota::ExceededError.from_response(StandardError.new("insufficient_quota"))
    [ "not json", "[]", "null", { "error" => "insufficient_quota" } ].each do |body|
      assert_nil Collavre::Quota::ExceededError.from_response(RubyLLM::Error.new(response: Faraday::Response.new(body: body)))
    end
  end

  test "recognizes Claude five-hour quota and uses the next reset in its stated timezone" do
    reset = Time.utc(2026, 11, 19, 20, 40) # 05:40 in Seoul on November 20
    travel_to(reset - 4.hours) do
      assert_equal reset, classify_claude.reset_at
    end
    travel_to(reset - 8.hours) do
      assert_equal reset - 4.hours, classify_claude(reset: "1:40am (Asia/Seoul)").reset_at
    end
    travel_to(Time.utc(2026, 11, 20, 6)) do
      assert_equal Time.utc(2026, 11, 20, 8, 40), classify_claude(reset: "5:40pm (Asia/Seoul)").reset_at
    end
    travel_to(reset + 30.seconds) do
      assert_equal Time.current, classify_claude.reset_at
    end
    travel_to(reset + 1.minute) do
      assert_nil classify_claude.reset_at
    end
  end

  test "prefers a valid Retry-After header and falls back to the Claude reset for an invalid header" do
    travel_to(Time.utc(2026, 11, 19, 18)) do
      assert_equal 2.minutes.from_now, classify_claude(headers: { "Retry-After" => "120" }).reset_at
      assert_equal Time.utc(2026, 11, 19, 20, 40), classify_claude(headers: { "Retry-After" => "0" }).reset_at
    end
  end

  test "uses existing backoff when the Claude reset clock or timezone is unusable" do
    [ "13:40am (Asia/Seoul)", "5:60am (Asia/Seoul)", "5:40am (Unknown/Zone)", "5:40am" ].each do |reset|
      assert_nil classify_claude(reset: reset).reset_at
    end
  end

  private

  def classify_claude(reset: "5:40am (Asia/Seoul)", headers: {})
    classify(status: 429, code: "rate_limit_exceeded", headers: headers,
             message: "Claude run failed: subtype=success: You've hit your 5-hour limit · resets #{reset}")
  end

  def classify(headers: {}, status: 429, code: "insufficient_quota", message: "Usage limit reached")
    response = Faraday::Response.new(status: status, response_headers: headers,
                                    body: { "error" => { "code" => code, "message" => message } }.to_json)
    Collavre::Quota::ExceededError.from_response(RubyLLM::Error.new(response: response))
  end
end

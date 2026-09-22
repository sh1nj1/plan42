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
      assert_nil Collavre::Quota::ExceededError.from_response(RubyLLM::Error.new(Faraday::Response.new(body: body)))
    end
  end

  private

  def classify(headers: {}, status: 429, code: "insufficient_quota", message: "Usage limit reached")
    response = Faraday::Response.new(status: status, response_headers: headers,
                                    body: { "error" => { "code" => code, "message" => message } }.to_json)
    Collavre::Quota::ExceededError.from_response(RubyLLM::Error.new(response))
  end
end

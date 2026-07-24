# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Collavre
  class HttpClientTest < ActiveSupport::TestCase
    ENDPOINT = "https://api.example.test/v1/resource"

    setup { WebMock.disable_net_connect! }
    teardown { WebMock.allow_net_connect! }

    test "get returns a parsed JSON response and success flag" do
      stub_request(:get, ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(status: 200, body: { ok: true }.to_json, headers: { "Content-Type" => "application/json" })

      client = HttpClient.new(default_headers: { "Authorization" => "Bearer tok" })
      response = client.get(ENDPOINT)

      assert_predicate response, :success?
      assert_equal 200, response.code
      assert_equal({ "ok" => true }, response.json)
    end

    test "get appends the query string from the url" do
      stub_request(:get, "#{ENDPOINT}?page=2").to_return(status: 200, body: "{}")

      HttpClient.new.get("#{ENDPOINT}?page=2")

      assert_requested :get, "#{ENDPOINT}?page=2"
    end

    test "post sends the body and per-request headers" do
      stub_request(:post, ENDPOINT).to_return(status: 201, body: { id: 1 }.to_json)

      response = HttpClient.new.post(
        ENDPOINT,
        body: { name: "x" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      assert_equal 201, response.code
      assert_requested :post, ENDPOINT,
        body: { name: "x" }.to_json,
        headers: { "Content-Type" => "application/json" }
    end

    test "non-success responses are returned, not raised" do
      stub_request(:get, ENDPOINT).to_return(status: 404, body: "nope")

      response = HttpClient.new.get(ENDPOINT)

      assert_not response.success?
      assert_equal 404, response.code
    end

    test "wraps a timeout in ConnectionError" do
      stub_request(:get, ENDPOINT).to_timeout

      assert_raises(HttpClient::ConnectionError) { HttpClient.new.get(ENDPOINT) }
    end

    test "wraps a socket error in ConnectionError" do
      stub_request(:get, ENDPOINT).to_raise(Errno::ECONNREFUSED)

      assert_raises(HttpClient::ConnectionError) { HttpClient.new.get(ENDPOINT) }
    end

    test "json returns nil for an empty body" do
      stub_request(:delete, ENDPOINT).to_return(status: 204, body: "")

      assert_nil HttpClient.new.delete(ENDPOINT).json
    end
  end
end

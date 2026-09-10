# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Collavre
  class HttpClientTest < ActiveSupport::TestCase
    ENDPOINT = "https://api.example.test/v1/resource"

    FakeStreamingResponse = Struct.new(:chunks, :content_length) do
      def code = "200"
      def message = "OK"
      def to_hash = {}
      def [](header) = header == "Content-Length" ? content_length : nil
      def read_body(&block) = chunks.each(&block)
    end

    FakeStreamingHttp = Struct.new(:response) do
      attr_accessor :use_ssl, :open_timeout, :read_timeout

      def request(_request)
        yield response
        response
      end
    end

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

    test "stops reading a response that exceeds the configured byte limit" do
      stub_request(:get, ENDPOINT).to_return(status: 200, body: "x" * 20)

      error = assert_raises(HttpClient::ResponseTooLarge) do
        HttpClient.new(max_response_bytes: 10).get(ENDPOINT)
      end

      assert_match(/10 bytes/, error.message)
    end

    test "enforces the byte limit while streaming without a content length" do
      response = FakeStreamingResponse.new([ "12345", "67890" ], nil)
      client = HttpClient.new(max_response_bytes: 8)

      error = assert_raises(HttpClient::ResponseTooLarge) do
        client.send(:bounded_response, FakeStreamingHttp.new(response), Net::HTTP::Get.new("/"))
      end

      assert_match(/8 bytes/, error.message)
    end

    test "returns a bounded response when the streamed body fits" do
      response = FakeStreamingResponse.new([ '{"ok":', "true}" ], "11")
      client = HttpClient.new(max_response_bytes: 16)

      result = client.send(:bounded_response, FakeStreamingHttp.new(response), Net::HTTP::Get.new("/"))

      assert_equal({ "ok" => true }, result.json)
    end

    test "enforces an overall deadline while a response keeps streaming" do
      response = FakeStreamingResponse.new([], nil)
      response.define_singleton_method(:read_body) do |&block|
        loop do
          sleep 0.01
          block.call("x")
        end
      end
      client = HttpClient.new(max_response_bytes: 1.megabyte, request_timeout: 0.05)
      http = FakeStreamingHttp.new(response)

      error = assert_raises(HttpClient::ConnectionError) do
        client.stub(:build_connection, http) { client.get(ENDPOINT) }
      end

      assert_match(/Timeout::Error/, error.message)
    end

    test "pins policy-protected requests to the validated address" do
      policy = Minitest::Mock.new
      policy.expect(:resolve!, [ "8.8.8.8" ], [ URI(ENDPOINT) ])
      client = HttpClient.new(endpoint_policy: policy)

      http = client.send(:build_connection, URI(ENDPOINT))

      assert_equal "api.example.test", http.address
      assert_equal "8.8.8.8", http.ipaddr
      policy.verify
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "net/http"
require Rails.root.join("lib/perf/fake_llm_server").to_s

module Perf
  class FakeLlmServerTest < ActiveSupport::TestCase
    setup do
      @server = FakeLlmServer.new(stream_seconds: 0.2, chunks: 2).start
    end

    teardown do
      @server.stop
    end

    def post_completion(body)
      Net::HTTP.post(URI("#{@server.base_url}/chat/completions"), JSON.generate(body),
                     "Content-Type" => "application/json")
    end

    test "lists a model for endpoint health probes" do
      response = Net::HTTP.get_response(URI("#{@server.base_url}/models"))

      assert_equal "200", response.code
      assert_equal "perf-fake", JSON.parse(response.body).dig("data", 0, "id")
    end

    test "streams an OpenAI chat completion tagged with the newest load-test message" do
      response = post_completion(stream: true, messages: [
        { role: "user", content: "old PERF-x-u1-a1" }, { role: "user", content: "new PERF-x-u2-a1" }
      ])

      assert_equal "200", response.code
      events = response.body.lines.grep(/\Adata: /).map { |line| line.delete_prefix("data: ").strip }
      assert_equal "[DONE]", events.last
      chunks = events[0..-2].map { |event| JSON.parse(event) }
      assert_equal "ack PERF-x-u2-a1 ", chunks.first.dig("choices", 0, "delta", "content")
      assert_equal "stop", chunks.last.dig("choices", 0, "finish_reason")
      assert_equal 1, @server.requests.size
      assert_equal "PERF-x-u2-a1", @server.requests.first.tag
      assert_operator @server.requests.first.finished_at, :>, @server.requests.first.started_at
    end

    test "answers non-streaming completions with the whole reply" do
      response = post_completion(messages: [ { role: "user", content: "no tag here" } ])

      body = JSON.parse(response.body)
      assert_equal "ack  .", body.dig("choices", 0, "message", "content")
      assert_nil @server.requests.first.tag
    end

    test "tracks how many requests were in flight at once" do
      threads = Array.new(3) { |i| Thread.new { post_completion(stream: true, messages: [ { content: "PERF-#{i}" } ]) } }
      threads.each(&:join)

      assert_equal 3, @server.peak_in_flight
      assert_equal 0, @server.in_flight
    end

    test "returns 404 for anything else and survives a client that hangs up" do
      assert_equal "404", Net::HTTP.get_response(URI("#{@server.base_url}/embeddings")).code

      TCPSocket.new("127.0.0.1", @server.port).close
      assert_equal "200", Net::HTTP.get_response(URI("#{@server.base_url}/models")).code
    end
  end
end

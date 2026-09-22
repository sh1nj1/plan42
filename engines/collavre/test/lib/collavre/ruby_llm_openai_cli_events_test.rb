# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Collavre
  # Guards the initializer patch that keeps cli-openai-proxy's x_cli_events,
  # which RubyLLM's OpenAI provider would otherwise drop.
  class RubyLlmOpenaiCliEventsTest < ActiveSupport::TestCase
    EVENT = { "id" => "t1", "phase" => "result", "name" => "Bash", "output" => "a.txt", "ok" => true }.freeze

    def provider
      RubyLLM::Providers::OpenAI.allocate
    end

    test "build_chunk keeps streamed x_cli_events next to reasoning_content" do
      chunk = provider.send(:build_chunk, "choices" => [
        { "delta" => { "reasoning_content" => "Bash(ls)", "x_cli_events" => [ EVENT, "junk" ] } }
      ])

      assert_equal [ EVENT ], chunk.cli_events
      assert_equal "Bash(ls)", chunk.thinking.text
    end

    test "build_chunk leaves cli_events empty for ordinary and malformed chunks" do
      assert_equal [], provider.send(:build_chunk, "choices" => [ { "delta" => { "content" => "hi" } } ]).cli_events
      assert_equal [], provider.send(:build_chunk, "usage" => { "prompt_tokens" => 1 }).cli_events
      assert_equal [], provider.send(:build_chunk, "choices" => [ { "delta" => { "x_cli_events" => EVENT } } ]).cli_events
    end

    test "parse_completion_response keeps x_cli_events of a non-streaming message" do
      body = { "choices" => [ { "message" => { "role" => "assistant", "content" => "done", "x_cli_events" => [ EVENT ] } } ] }
      message = provider.send(:parse_completion_response, OpenStruct.new(body: body))

      assert_equal "done", message.content
      assert_equal [ EVENT ], message.cli_events

      plain = { "choices" => [ { "message" => { "role" => "assistant", "content" => "done" } } ] }
      assert_equal [], provider.send(:parse_completion_response, OpenStruct.new(body: plain)).cli_events
      assert_nil provider.send(:parse_completion_response, OpenStruct.new(body: {}))
    end

    test "messages from other providers report no cli_events" do
      assert_equal [], RubyLLM::Message.new(role: :assistant, content: "hi").cli_events
    end
  end
end

# frozen_string_literal: true

module Collavre
  module RubyLlmPatches
    # cli-openai-proxy runs every tool inside the CLI (Claude Code / Codex) and,
    # when a request opts in with `x_cli_events: "reasoning"`, reports them as
    # structured events: `delta.x_cli_events` on a streaming chunk, or
    # `message.x_cli_events` on a non-streaming response. Each event is
    # `{ id, phase: "call"|"result", name, input, output, exitCode, ok, parentId }`.
    #
    # RubyLLM (through 2.1.1) knows nothing of the key and drops it while
    # building the Chunk / Message, so this patch carries the raw events over as
    # `#cli_events` (always an Array of Hashes, empty when absent).
    module MessageCliEvents
      attr_writer :cli_events

      def cli_events
        @cli_events || []
      end
    end

    module OpenAICliEvents
      def self.extract(value)
        value.is_a?(Array) ? value.grep(Hash) : []
      end

      def build_chunk(data)
        chunk = super
        chunk.cli_events = OpenAICliEvents.extract(data.dig("choices", 0, "delta", "x_cli_events"))
        chunk
      end

      def parse_completion_body(body, raw:)
        message = super
        message&.cli_events = OpenAICliEvents.extract(body.dig("choices", 0, "message", "x_cli_events"))
        message
      end
    end
  end
end

RubyLLM::Message.include(Collavre::RubyLlmPatches::MessageCliEvents)
RubyLLM::Protocols::ChatCompletions.prepend(Collavre::RubyLlmPatches::OpenAICliEvents)

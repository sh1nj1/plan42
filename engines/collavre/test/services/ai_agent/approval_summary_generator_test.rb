# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class ApprovalSummaryGeneratorTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @original_key = ENV["GEMINI_API_KEY"]
        ENV["GEMINI_API_KEY"] = "test-key"
      end

      teardown do
        ENV["GEMINI_API_KEY"] = @original_key
      end

      test "generates summary with tool name and arguments" do
        generator = ApprovalSummaryGenerator.new(
          tool_name: "update_creative",
          arguments: { "creative_id" => 123, "description" => "New title" },
          creative: @creative
        )

        mock_chat = Object.new
        mock_chat.define_singleton_method(:with_instructions) { |_| mock_chat }
        mock_chat.define_singleton_method(:ask) { |_prompt|
          OpenStruct.new(content: "Updates the description of creative #123 to 'New title'.")
        }

        RubyLLM.stub(:context, ->(&block) {
          config = OpenStruct.new(gemini_api_key: nil)
          block.call(config)
          mock_context = Object.new
          mock_context.define_singleton_method(:chat) { |model:| mock_chat }
          mock_context
        }) do
          result = generator.generate
          assert_equal "Updates the description of creative #123 to 'New title'.", result
        end
      end

      test "returns nil when LLM call fails" do
        generator = ApprovalSummaryGenerator.new(
          tool_name: "update_creative",
          arguments: { "creative_id" => 123 },
          creative: @creative
        )

        RubyLLM.stub(:context, ->(&_block) { raise StandardError, "API error" }) do
          result = generator.generate
          assert_nil result
        end
      end

      test "returns nil when API key is blank" do
        ENV["GEMINI_API_KEY"] = ""

        generator = ApprovalSummaryGenerator.new(
          tool_name: "update_creative",
          arguments: {},
          creative: nil
        )

        result = generator.generate
        assert_nil result
      end

      test "includes creative context in prompt when available" do
        generator = ApprovalSummaryGenerator.new(
          tool_name: "delete_creative",
          arguments: { "creative_id" => 456 },
          creative: @creative
        )

        captured_prompt = nil
        mock_chat = Object.new
        mock_chat.define_singleton_method(:with_instructions) { |_| mock_chat }
        mock_chat.define_singleton_method(:ask) { |prompt|
          captured_prompt = prompt
          OpenStruct.new(content: "Deletes creative #456.")
        }

        RubyLLM.stub(:context, ->(&block) {
          config = OpenStruct.new(gemini_api_key: nil)
          block.call(config)
          mock_context = Object.new
          mock_context.define_singleton_method(:chat) { |model:| mock_chat }
          mock_context
        }) do
          generator.generate
          assert_includes captured_prompt, "delete_creative"
          assert_includes captured_prompt, "456"
          assert_includes captured_prompt, "Context:"
        end
      end

      test "works without creative context" do
        generator = ApprovalSummaryGenerator.new(
          tool_name: "some_tool",
          arguments: { "key" => "value" },
          creative: nil
        )

        captured_prompt = nil
        mock_chat = Object.new
        mock_chat.define_singleton_method(:with_instructions) { |_| mock_chat }
        mock_chat.define_singleton_method(:ask) { |prompt|
          captured_prompt = prompt
          OpenStruct.new(content: "Executes some_tool with key=value.")
        }

        RubyLLM.stub(:context, ->(&block) {
          config = OpenStruct.new(gemini_api_key: nil)
          block.call(config)
          mock_context = Object.new
          mock_context.define_singleton_method(:chat) { |model:| mock_chat }
          mock_context
        }) do
          result = generator.generate
          assert_equal "Executes some_tool with key=value.", result
          refute_includes captured_prompt, "Context:"
        end
      end

      test "handles nil arguments" do
        generator = ApprovalSummaryGenerator.new(
          tool_name: "some_tool",
          arguments: nil,
          creative: nil
        )

        mock_chat = Object.new
        mock_chat.define_singleton_method(:with_instructions) { |_| mock_chat }
        mock_chat.define_singleton_method(:ask) { |_prompt|
          OpenStruct.new(content: "Executes some_tool with no arguments.")
        }

        RubyLLM.stub(:context, ->(&block) {
          config = OpenStruct.new(gemini_api_key: nil)
          block.call(config)
          mock_context = Object.new
          mock_context.define_singleton_method(:chat) { |model:| mock_chat }
          mock_context
        }) do
          result = generator.generate
          assert_equal "Executes some_tool with no arguments.", result
        end
      end
    end
  end
end

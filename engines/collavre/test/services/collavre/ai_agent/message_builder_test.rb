require "test_helper"

module Collavre
  module AiAgent
    class MessageBuilderTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)

        @comment = @creative.comments.create!(content: "Hello AI", user: @user)
      end

      test "appends referenced creative context from markdown links" do
        # Create a second creative to reference
        other_creative = Creative.create!(
          description: "<p>Other Project</p>",
          user: @user,
          progress: 0.0
        )

        context = {
          "comment" => {
            "id" => @comment.id,
            "content" => "Check this: [Other Project](/creatives/#{other_creative.id})"
          },
          "creative" => { "id" => @creative.id }
        }

        @comment.update!(content: context.dig("comment", "content"))

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build

        referenced_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.include?("Referenced Creative") }
        assert_not_nil referenced_msg, "Should include referenced creative context"
        assert_includes referenced_msg[:parts].first[:text], "Other Project"
        assert_includes referenced_msg[:parts].first[:text], other_creative.id.to_s
      end

      test "does not duplicate current creative in referenced contexts" do
        context = {
          "comment" => {
            "id" => @comment.id,
            "content" => "Self ref: [Self](/creatives/#{@creative.id})"
          },
          "creative" => { "id" => @creative.id }
        }

        @comment.update!(content: context.dig("comment", "content"))

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build

        referenced_msgs = messages.select { |m| m[:parts]&.first&.dig(:text)&.include?("Referenced Creative") }
        assert_empty referenced_msgs, "Should not include current creative as referenced"
      end

      test "appends context creatives from effective_context_ids" do
        dev_rules = Creative.create!(
          description: "<p>Dev Rules</p>",
          user: @user,
          progress: 1.0
        )

        # Set context_ids on creative's data
        @creative.update!(data: { "context_ids" => [ dev_rules.id ] })

        context = {
          "comment" => { "id" => @comment.id, "content" => "Implement feature X" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build

        context_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.include?("Context Creative") }
        assert_not_nil context_msg, "Should include context creative"
        assert_includes context_msg[:parts].first[:text], "Dev Rules"
      end

      test "excludes disabled context creatives" do
        dev_rules = Creative.create!(
          description: "<p>Dev Rules</p>",
          user: @user,
          progress: 1.0
        )

        @creative.update!(data: {
          "context_ids" => [ dev_rules.id ],
          "disabled_context_ids" => [ dev_rules.id ]
        })

        context = {
          "comment" => { "id" => @comment.id, "content" => "Implement feature X" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build

        context_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.include?("Context Creative") }
        assert_nil context_msg, "Should not include disabled context creative"
      end

      test "skips self context when disabled_self_context is true" do
        @creative.update!(data: { "disabled_self_context" => true })

        context = {
          "comment" => { "id" => @comment.id, "content" => "Do something" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build

        creative_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.start_with?("Creative (id:") }
        assert_nil creative_msg, "Should not include self creative context when disabled"
      end

      test "handles message without creative links" do
        context = {
          "comment" => {
            "id" => @comment.id,
            "content" => "Just a plain message"
          },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build

        referenced_msgs = messages.select { |m| m[:parts]&.first&.dig(:text)&.include?("Referenced Creative") }
        assert_empty referenced_msgs
      end
    end
  end
end

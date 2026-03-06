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

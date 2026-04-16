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
        result = builder.build
        messages = result[:messages]

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
        result = builder.build
        messages = result[:messages]

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
        result = builder.build
        messages = result[:messages]

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
        result = builder.build
        messages = result[:messages]

        context_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.include?("Context Creative") }
        assert_nil context_msg, "Should not include disabled context creative"
      end

      test "includes ancestry breadcrumb in full subtree context" do
        context = {
          "comment" => { "id" => @comment.id, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build
        messages = result[:messages]

        creative_msg = messages.find { |m| m[:kind] == :creative_context }
        assert_not_nil creative_msg
        assert_includes creative_msg[:parts].first[:text], "Path:"
      end

      test "injects only ancestry chain when disabled_self_context is true" do
        @creative.update!(data: { "disabled_self_context" => true })

        context = {
          "comment" => { "id" => @comment.id, "content" => "Do something" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build
        messages = result[:messages]

        # Should NOT include full subtree
        full_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.start_with?("Creative (id:") }
        assert_nil full_msg, "Should not include full creative subtree when disabled"

        # Should include ancestry path
        ancestry_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.start_with?("Current Creative (id:") }
        assert_not_nil ancestry_msg, "Should include ancestry chain when self-context disabled"
        assert_includes ancestry_msg[:parts].first[:text], "Path:"
      end

      test "deduplicates context and referenced creatives" do
        dev_rules = Creative.create!(
          description: "<p>Dev Rules</p>",
          user: @user,
          progress: 1.0
        )

        # Same creative as both context AND referenced via markdown link
        @creative.update!(data: { "context_ids" => [ dev_rules.id ] })

        context = {
          "comment" => {
            "id" => @comment.id,
            "content" => "Check [Dev Rules](/creatives/#{dev_rules.id})"
          },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build
        messages = result[:messages]

        # Should appear as Context Creative, NOT also as Referenced Creative
        context_msgs = messages.select { |m| m[:parts]&.first&.dig(:text)&.include?("Context Creative") }
        referenced_msgs = messages.select { |m| m[:parts]&.first&.dig(:text)&.include?("Referenced Creative") }
        assert_equal 1, context_msgs.size, "Should inject context creative once"
        assert_empty referenced_msgs, "Should not duplicate as referenced creative"
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
        result = builder.build
        messages = result[:messages]

        referenced_msgs = messages.select { |m| m[:parts]&.first&.dig(:text)&.include?("Referenced Creative") }
        assert_empty referenced_msgs
      end

      test "build returns Hash with messages, first_message, and context_changed" do
        context = {
          "comment" => { "id" => @comment.id, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build

        assert_instance_of Hash, result
        assert result.key?(:messages)
        assert result.key?(:first_message)
        assert result.key?(:context_changed)
        assert_instance_of Array, result[:messages]
      end

      test "first_message is true when no chat history exists" do
        context = {
          "comment" => { "id" => @comment.id, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build

        assert result[:first_message], "Should be first_message when no chat history"
      end

      test "first_message is false when chat history exists" do
        # Create prior history
        @creative.comments.create!(content: "Prior question", user: @user, topic_id: @comment.topic_id)
        @creative.comments.create!(content: "Prior answer", user: @agent, topic_id: @comment.topic_id)

        context = {
          "comment" => { "id" => @comment.id, "content" => "Follow-up" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build

        assert_not result[:first_message], "Should not be first_message when history exists"
      end

      test "messages have kind tags" do
        context = {
          "comment" => { "id" => @comment.id, "content" => "Hello" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build
        messages = result[:messages]

        # Should have creative_context and trigger at minimum
        kinds = messages.map { |m| m[:kind] }
        assert_includes kinds, :creative_context
        assert_includes kinds, :trigger
      end

      test "context_changed detects creative update after last reply" do
        # Create prior conversation
        @creative.comments.create!(content: "Question", user: @user, topic_id: @comment.topic_id)
        agent_reply = @creative.comments.create!(content: "Answer", user: @agent, topic_id: @comment.topic_id)

        # Update creative AFTER the agent's reply
        @creative.update!(description: "<p>Updated content</p>")
        assert @creative.updated_at > agent_reply.created_at

        context = {
          "comment" => { "id" => @comment.id, "content" => "Follow-up" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build

        assert result[:context_changed], "Should detect creative content change"
      end

      test "context_changed is false when creative unchanged since last reply" do
        # Create prior conversation
        @creative.comments.create!(content: "Question", user: @user, topic_id: @comment.topic_id)
        @creative.comments.create!(content: "Answer", user: @agent, topic_id: @comment.topic_id)

        context = {
          "comment" => { "id" => @comment.id, "content" => "Follow-up" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build

        assert_not result[:context_changed], "Should not flag context_changed when unchanged"
      end

      test "context_changed detects agent settings update" do
        # Create prior conversation
        @creative.comments.create!(content: "Question", user: @user, topic_id: @comment.topic_id)
        agent_reply = @creative.comments.create!(content: "Answer", user: @agent, topic_id: @comment.topic_id)

        # Update agent AFTER the agent's reply
        @agent.update!(name: "Updated Bot Name")
        assert @agent.updated_at > agent_reply.created_at

        context = {
          "comment" => { "id" => @comment.id, "content" => "Follow-up" },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        result = builder.build

        assert result[:context_changed], "Should detect agent settings change"
      end
    end
  end
end

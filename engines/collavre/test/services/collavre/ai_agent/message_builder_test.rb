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
        assert_includes creative_msg[:parts].first[:text], "Creative Path:"
        assert_match(/\(id: #{@creative.id}\)/, creative_msg[:parts].first[:text])
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

        # Both modes now use "Creative Path:" format
        ancestry_msg = messages.find { |m| m[:parts]&.first&.dig(:text)&.start_with?("Creative Path:") }
        assert_not_nil ancestry_msg, "Should include ancestry chain when self-context disabled"
        assert_match(/\(id: #{@creative.id}\)/, ancestry_msg[:parts].first[:text])
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

      # An approval-action comment (approve button / approved label) is a human
      # decision surface. Blocking it at the dispatch seams is not enough: the
      # chat-history query would still load it as context on a later dispatch,
      # so its content must be excluded here too (Comment#approval_action?).
      test "excludes approval-action comments from chat history" do
        # Ordinary prior comment — must remain in the agent's chat history.
        @creative.comments.create!(
          content: "prior ordinary message",
          user: @user,
          topic_id: @comment.topic_id
        )
        # Public approval-action comment authored by the agent (non-nil user_id,
        # so it survives the existing where.not(user_id: nil) filter) — the leak
        # vector: its content must never enter chat history.
        @creative.comments.create!(
          content: "TOOL APPROVAL secret-payload",
          user: @agent,
          topic_id: @comment.topic_id,
          approver: @user,
          action: %({"action":"execute_tool","tool_name":"write_file"}),
          private: false
        )

        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        history = builder.build[:messages]
          .select { |m| m[:kind] == :chat_history }
          .map { |m| m[:parts].first[:text] }
          .join("\n")

        assert_includes history, "prior ordinary message",
          "ordinary prior comments must remain in chat history"
        assert_not_includes history, "secret-payload",
          "approval-action comment content must never enter chat history"
      end

      # Comments folded into this turn by Orchestration::TaskCoalescer belong in
      # the trigger, not in chat history: a session-backed agent receives only
      # the :trigger message (SessionContextResolver#incremental_payload).
      test "merged comments are folded into the trigger message" do
        merged = @creative.comments.create!(
          content: "earlier burst message", user: @user, topic_id: @comment.topic_id
        )
        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => [ merged.id ]
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        messages = builder.build[:messages]

        trigger = messages.find { |m| m[:kind] == :trigger }
        assert_includes trigger[:parts].first[:text], "earlier burst message"
        assert_includes trigger[:parts].first[:text], @comment.content
      end

      test "merged comments are not repeated in chat history" do
        merged = @creative.comments.create!(
          content: "earlier burst message", user: @user, topic_id: @comment.topic_id
        )
        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => [ merged.id ]
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        history = builder.build[:messages]
          .select { |m| m[:kind] == :chat_history }
          .map { |m| m[:parts].first[:text] }
          .join("\n")

        assert_not_includes history, "earlier burst message",
          "a comment already inlined in the trigger must not be sent twice"
      end

      # The exclusion above pairs with the trigger actually carrying the comment.
      # An oversized burst drops its oldest blocks (MergedTriggerComments budgets
      # by chat_history_size), and excluding a comment the trigger no longer
      # renders would delete it from the turn entirely — history is separately
      # budgeted and can still carry it.
      test "a merged comment dropped from the trigger falls back to chat history" do
        @agent.update!(agent_conf: "context:\n  chat_history_size: 200")
        dropped = @creative.comments.create!(
          content: "D" * 150, user: @user, topic_id: @comment.topic_id
        )
        kept = @creative.comments.create!(
          content: "K" * 150, user: @user, topic_id: @comment.topic_id
        )
        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => [ dropped.id, kept.id ]
        }

        messages = MessageBuilder.new(
          agent: @agent, context: context, original_comment: @comment
        ).build[:messages]
        trigger = messages.find { |m| m[:kind] == :trigger }[:parts].first[:text]
        history = messages.select { |m| m[:kind] == :chat_history }
                          .map { |m| m[:parts].first[:text] }.join("\n")

        assert_includes trigger, "K" * 150, "the newest merged comment stays in the trigger"
        assert_not_includes trigger, "D" * 150
        assert_includes history, "D" * 150,
          "a comment cut from the trigger must not vanish from the turn"
      end

      test "merged comments carry their image attachments into the trigger" do
        merged = @creative.comments.create!(
          content: "with a picture", user: @user, topic_id: @comment.topic_id
        )
        merged.images.attach(
          io: StringIO.new(one_pixel_png), filename: "pixel.png", content_type: "image/png"
        )
        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => [ merged.id ]
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        trigger = builder.build[:messages].find { |m| m[:kind] == :trigger }

        assert_equal 1, trigger[:parts].count { |p| p.key?(:image) },
          "an image posted in a coalesced comment must still reach the agent"
      end

      # The history limit counts *delivered* history. Merged comments move into
      # the trigger, so letting them occupy history slots hands the agent a burst
      # with no conversation behind it — and, when they fill the limit outright,
      # flags the turn as first_message.
      test "coalesced comments do not crowd older messages out of chat history" do
        older = @creative.comments.create!(
          content: "older context worth keeping", user: @user, topic_id: @comment.topic_id
        )
        burst = 3.times.map do |i|
          @creative.comments.create!(
            content: "burst message #{i}", user: @user, topic_id: @comment.topic_id
          )
        end
        anchor = burst.last

        context = {
          "comment" => { "id" => anchor.id, "content" => anchor.content },
          "creative" => { "id" => @creative.id },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => burst.map(&:id)
        }

        result = @agent.stub(:chat_history_limit, 3) do
          MessageBuilder.new(agent: @agent, context: context, original_comment: anchor).build
        end
        history = result[:messages]
          .select { |m| m[:kind] == :chat_history }
          .map { |m| m[:parts].first[:text] }
          .join("\n")

        assert_includes history, "older context worth keeping",
          "eligible older messages must backfill the slots merged comments vacate"
        assert_not result[:first_message],
          "a burst that fills the limit must not make the turn look like a first message"
        assert_not_includes history, "burst message",
          "merged comments still belong in the trigger, not in history"
      end

      # An absorbed comment's creative links have to be resolved too: the merged
      # text reaches the agent, so the subtree it points at must reach it as well.
      test "creative links in coalesced comments are injected as referenced context" do
        other_creative = Creative.create!(
          description: "<p>Linked Project</p>", user: @user, progress: 0.0
        )
        merged = @creative.comments.create!(
          content: "look at [Linked Project](/creatives/#{other_creative.id})",
          user: @user, topic_id: @comment.topic_id
        )
        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => [ merged.id ]
        }

        messages = MessageBuilder.new(
          agent: @agent, context: context, original_comment: @comment
        ).build[:messages]

        referenced = messages.find do |m|
          m[:kind] == :referenced_creative &&
            m[:parts].first[:text].include?("id: #{other_creative.id}")
        end
        assert_not_nil referenced,
          "a creative referenced only by an absorbed comment must still be injected"
        assert_includes referenced[:parts].first[:text], "Linked Project"
      end

      test "no merged ids leaves the trigger message unchanged" do
        context = {
          "comment" => { "id" => @comment.id, "content" => @comment.content },
          "creative" => { "id" => @creative.id }
        }

        builder = MessageBuilder.new(agent: @agent, context: context, original_comment: @comment)
        trigger = builder.build[:messages].find { |m| m[:kind] == :trigger }

        assert_equal @comment.content, trigger[:parts].first[:text]
      end

      private

      def one_pixel_png
        Base64.decode64(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )
      end
    end
  end
end

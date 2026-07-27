# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class MergedTriggerCommentsTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Merged", creative: @creative, user: @user)
      end

      def comment(body, user: @user, created_at: nil)
        c = Comment.create!(
          creative: @creative, user: user, topic: @topic, content: body, skip_dispatch: true
        )
        c.update_columns(created_at: created_at) if created_at
        c
      end

      def context_with(anchor, merged)
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "comment" => { "id" => anchor.id, "content" => anchor.content },
          Orchestration::TaskCoalescer::PAYLOAD_KEY => merged.map(&:id)
        }
      end

      test "renders merged comments oldest first, labelled by speaker" do
        older = comment("first", created_at: 3.minutes.ago)
        newer = comment("second", created_at: 2.minutes.ago)
        anchor = comment("third", created_at: 1.minute.ago)

        blocks = MergedTriggerComments.for(context_with(anchor, [ newer, older ]), agent: @agent)

        assert_equal [ "[#{@user.name}]: first", "[#{@user.name}]: second" ], blocks.map(&:text)
      end

      # Comment ids are the app's causal sequence (see CommentsController: created_at
      # is stamped by whichever process wrote the row, so a burst inserted by
      # concurrent workers can be backdated out of order). Ordering the merged
      # prompt by created_at can therefore hand the agent "ignore that" before the
      # instruction it retracts.
      test "orders merged comments by id when created_at is skewed" do
        first = comment("do X", created_at: 1.minute.ago)
        second = comment("ignore that", created_at: 5.minutes.ago)
        assert_operator first.id, :<, second.id
        anchor = comment("and now Y")

        blocks = MergedTriggerComments.for(context_with(anchor, [ first, second ]), agent: @agent)

        assert_equal [ "[#{@user.name}]: do X", "[#{@user.name}]: ignore that" ],
                     blocks.map(&:text),
                     "insertion order is the causal order, not the stamped timestamp"
      end

      test "orders merged comments by id when created_at ties" do
        same = 2.minutes.ago
        first = comment("do X", created_at: same)
        second = comment("ignore that", created_at: same)
        anchor = comment("and now Y")

        blocks = MergedTriggerComments.for(context_with(anchor, [ second, first ]), agent: @agent)

        assert_equal [ "[#{@user.name}]: do X", "[#{@user.name}]: ignore that" ],
                     blocks.map(&:text)
      end

      test "excludes the anchor comment from the merged blocks" do
        anchor = comment("only")

        blocks = MergedTriggerComments.for(context_with(anchor, [ anchor ]), agent: @agent)

        assert_empty blocks
      end

      test "strips a self-mention of the agent from merged text" do
        merged = comment("@#{@agent.name}: please look", created_at: 2.minutes.ago)
        anchor = comment("and this too", created_at: 1.minute.ago)

        blocks = MergedTriggerComments.for(context_with(anchor, [ merged ]), agent: @agent)

        assert_equal "[#{@user.name}]: please look", blocks.first.text
      end

      test "skips private and approval-surface comments" do
        private_comment = Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: "secret",
          private: true, skip_dispatch: true
        )
        anchor = comment("anchor")

        blocks = MergedTriggerComments.for(context_with(anchor, [ private_comment ]), agent: @agent)

        assert_empty blocks
      end

      test "prepend_to leaves content untouched when nothing was merged" do
        anchor = comment("anchor")
        context = context_with(anchor, [])

        assert_equal "anchor", MergedTriggerComments.prepend_to("anchor", context, agent: @agent)
      end

      test "prepend_to puts merged comments above the anchor content" do
        merged = comment("earlier", created_at: 2.minutes.ago)
        anchor = comment("latest", created_at: 1.minute.ago)

        result = MergedTriggerComments.prepend_to(
          "latest", context_with(anchor, [ merged ]), agent: @agent
        )

        assert_equal "[#{@user.name}]: earlier\n\nlatest", result
      end

      # ClaudeChannelAdapter is the agent's ONLY input on the Claude Channel
      # path: no chat history is sent, so a merged comment that is not inlined
      # here never reaches the agent at all.
      test "claude channel dispatch carries the merged comments inline" do
        agent = User.create!(
          email: "cc-merged-#{SecureRandom.hex(4)}@agent.collavre.local",
          password: SecureRandom.hex(32), name: "Claude Merged",
          llm_vendor: "anthropic", llm_model: "claude-code",
          created_by_id: @user.id, searchable: false
        )
        merged = comment("earlier point", created_at: 2.minutes.ago)
        anchor = comment("later point", created_at: 1.minute.ago)

        broadcasts = []
        ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << data } do
          ClaudeChannelAdapter.new(agent: agent, context: context_with(anchor, [ merged ])).deliver
        end

        content = broadcasts.first[:comment][:content]
        assert_includes content, "earlier point"
        assert_includes content, "later point"
      end
    end
  end
end

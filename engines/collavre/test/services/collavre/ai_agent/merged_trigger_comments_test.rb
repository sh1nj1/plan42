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

      # MessageBuilder budgets chat history by chat_history_size, but the merged
      # blocks go into the trigger, which had no budget at all. A burst is
      # exactly the input that makes that asymmetry bite: coalescing turns N
      # comments into one indivisible message, so an oversized burst does not
      # degrade — the whole turn fails.
      # Dropping the oldest blocks rested on "the history window carries them
      # instead". It does not: MessageBuilder#append_chat_history applies its own
      # chat_history_limit *and* the same size budget over the whole preceding
      # conversation, and it never carries attachments at all. So a dropped block
      # is a user comment that may reach the agent through no channel — and its
      # images through none, ever. Keep every block and shrink instead; the
      # trigger is the only path with a guarantee.
      test "keeps every merged comment in the trigger once over the size budget" do
        @agent.update!(agent_conf: "context:\n  chat_history_size: 200")
        oldest = comment("O" * 150)
        middle = comment("M" * 150)
        newest = comment("N" * 150)
        anchor = comment("anchor")

        blocks = MergedTriggerComments.for(
          context_with(anchor, [ oldest, middle, newest ]), agent: @agent
        )

        assert_equal [ oldest.id, middle.id, newest.id ], blocks.filter_map { |b| b.comment&.id },
                     "no merged comment may be dropped onto a channel that does not guarantee it"
        assert_operator blocks.sum { |b| b.text.length }, :<=, 200,
                        "shrinking still has to respect the budget"
        assert_match(/#{Regexp.escape(MergedTriggerComments::TRUNCATION_SUFFIX)}/,
                     blocks.map(&:text).join("\n\n"),
                     "a silent truncation reads to the agent as if nothing was cut")
      end

      # Control: the budget must not fire on ordinary bursts. Under the limit,
      # every merged comment is still rendered in full.
      test "renders every merged comment when the burst fits the budget" do
        @agent.update!(agent_conf: "context:\n  chat_history_size: 100000")
        older = comment("first point")
        newer = comment("second point")
        anchor = comment("anchor")

        blocks = MergedTriggerComments.for(context_with(anchor, [ older, newer ]), agent: @agent)

        assert_equal 2, blocks.size
        rendered = blocks.map(&:text).join("\n\n")
        assert_includes rendered, "first point"
        assert_includes rendered, "second point"
        refute_match(/omitted/, rendered)
      end

      # Dropping the oldest blocks rests on "the history window carries them
      # instead" (MessageBuilder#merged_comment_ids). That fallback does not
      # exist for a session-backed agent: SessionContextResolver
      # #incremental_payload keeps only the :trigger message, so a block dropped
      # here is a user comment with no remaining delivery path — the exact loss
      # the spec built coalescing to prevent. Shrink the blocks instead.
      test "a session-backed agent keeps every merged comment in the trigger" do
        @agent.update!(agent_conf: "session:\n  enabled: true\ncontext:\n  chat_history_size: 200")
        oldest = comment("O" * 150)
        middle = comment("M" * 150)
        newest = comment("N" * 150)
        anchor = comment("anchor")

        blocks = MergedTriggerComments.for(
          context_with(anchor, [ oldest, middle, newest ]), agent: @agent
        )

        assert_equal [ oldest.id, middle.id, newest.id ], blocks.filter_map { |b| b.comment&.id },
                     "no merged comment may be dropped when the trigger is the only channel"
        assert_operator blocks.sum { |b| b.text.length }, :<=, 200,
                        "shrinking still has to respect the budget"
      end

      # The budget loop breaks on the first block that does not fit, so a single
      # oversized comment left `kept` empty and the method returned nothing but
      # the omission marker — every merged comment gone, including the newest,
      # which is the one the anchor is replying to.
      test "keeps the newest merged comment even when it alone exceeds the budget" do
        @agent.update!(agent_conf: "context:\n  chat_history_size: 100")
        older = comment("O" * 80)
        newest = comment("N" * 500)
        anchor = comment("anchor")

        blocks = MergedTriggerComments.for(context_with(anchor, [ older, newest ]), agent: @agent)

        assert_includes blocks.filter_map { |b| b.comment&.id }, newest.id,
                        "a marker-only result deletes the newest merged comment too"
        assert_operator blocks.sum { |b| b.text.length }, :<=, 100,
                        "the surviving block must be trimmed to the budget"
      end

      # "Shrink instead of drop" is the whole point of the session-backed branch:
      # the trigger is that agent's only channel, so a block it does not carry is
      # a user comment with no delivery path. Collapsing to the newest block when
      # the per-block share gets small breaks exactly that promise — and takes
      # every other block's image attachments with it, which the text budget does
      # not even measure.
      test "a session-backed agent keeps every merged comment when the share is tiny" do
        @agent.update!(agent_conf: "session:\n  enabled: true\ncontext:\n  chat_history_size: 60")
        merged = 5.times.map { |i| comment("point #{i} " * 10) }
        anchor = comment("anchor")

        blocks = MergedTriggerComments.for(context_with(anchor, merged), agent: @agent)

        assert_equal merged.map(&:id), blocks.filter_map { |b| b.comment&.id },
                     "a tiny share is a reason to compact every block, not to drop four of them"
        assert_operator blocks.sum { |b| b.text.length }, :<=, 60,
                        "compacting still has to respect the budget"
      end

      # The merged set is read by id alone. A comment moved to another creative
      # while the task waited (CommentMoveService#perform_move reassigns
      # creative_id) would still be rendered into this turn's trigger, handing
      # the agent content — and image attachments — from a creative it may have
      # no share on. refresh_deferred_context! already scopes its lookup to the
      # payload's creative/topic; this one has to ask the same question.
      test "ignores merged comments that no longer belong to the turn's creative" do
        stayed = comment("still here")
        moved = comment("moved away")
        anchor = comment("anchor")
        other = Creative.create!(description: "Elsewhere", user: @user)
        moved.update!(creative: other, topic_id: nil)

        blocks = MergedTriggerComments.for(context_with(anchor, [ stayed, moved ]), agent: @agent)

        assert_equal [ stayed.id ], blocks.filter_map { |b| b.comment&.id },
                     "a comment moved out of the creative is no longer part of this turn"
      end
    end
  end
end

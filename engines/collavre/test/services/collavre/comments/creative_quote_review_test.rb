require "test_helper"

module Collavre
  module Comments
    class CreativeQuoteReviewTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:ai_bot)
        @document = Creative.create!(description: "<p>Document</p>", user: @user)
        @section = Creative.create!(description: "<p>Section</p>", user: @user, parent: @document)
        @inside = Creative.create!(description: "<p>Inside</p>", user: @user, parent: @section)
        @outside = Creative.create!(description: "<p>Outside</p>", user: @user, parent: @document)
        @topic = Topic.create!(creative: @document, user: @user, name: "Doc chat")
        @trigger = Comment.create!(creative: @document, topic: @topic, user: @user, content: "> Section",
                                   quoted_creative: @section, quoted_text: "Section", skip_dispatch: true)
        @task = Task.create!(agent: @agent, creative: @document, topic_id: @topic.id, name: "Review",
                             status: "done", trigger_comment_id: @trigger.id)
        @reply = Comment.create!(creative: @document, topic: @topic, user: @agent, content: "Done", task: @task,
                                 skip_dispatch: true)
      end

      test "finds the latest change set of a quote task for the agent's reply" do
        older = change_set([ change(@inside) ])
        newer = change_set([ change(@inside) ])

        review = CreativeQuoteReview.for_reply(@reply)

        assert_equal newer, review.change_set
        assert_not_equal older, review.change_set
        assert_equal @section, review.quoted_creative
        assert_equal @document, review.scope_creative
      end

      test "replies outside a quote task show nothing" do
        change_set([ change(@inside) ])
        plain_trigger = Comment.create!(creative: @document, topic: @topic, user: @user, content: "hi", skip_dispatch: true)
        @task.update!(trigger_comment_id: plain_trigger.id)

        assert_nil CreativeQuoteReview.for_reply(@reply)
        assert_nil CreativeQuoteReview.for_reply(@trigger)
        assert_nil CreativeQuoteReview.for_reply(Comment.new(user: @agent))
      end

      test "a quote task without a change set shows nothing" do
        assert_nil CreativeQuoteReview.for_reply(@reply)
      end

      test "flags existing and created creatives outside the quoted subtree" do
        set = change_set([
          change(@inside),
          change(@outside),
          change_attrs(-1, @section.id),
          change_attrs(-2, @document.id),
          change_attrs(-3, -2)
        ])

        review = CreativeQuoteReview.new(@reply, set, @trigger)

        assert_equal [ @outside.id, -2 ], review.out_of_scope_ids
      end

      test "falls back to the quoted creative when the chat creative does not cover the change" do
        other = Creative.create!(description: "<p>Elsewhere</p>", user: @user)
        reply = Comment.create!(creative: other, user: @agent, content: "Done", skip_dispatch: true)
        set = change_set([ change(@inside) ])

        assert_equal @section, CreativeQuoteReview.new(reply, set, @trigger).scope_creative
        unrelated = Creative.create!(description: "<p>Unrelated</p>", user: @user)
        assert_nil CreativeQuoteReview.new(reply, change_set([ change(unrelated) ]), @trigger).scope_creative
      end

      test "a rejection notice is left only for a document review" do
        set = change_set([ change(@inside) ])
        assert_difference -> { Comment.where(topic: @topic, user_id: nil).count }, 1 do
          CreativeQuoteRejectionNotice.call(set)
        end

        @trigger.update_columns(review_type: Comment.review_types[:question])
        assert_no_difference -> { Comment.count } do
          CreativeQuoteRejectionNotice.call(set)
          CreativeQuoteRejectionNotice.call(CreativeChangeSet.new)
        end
      end

      private

      def change_set(changes)
        set = CreativeChangeSet.create!(actor_kind: "agent", origin: "tool", status: "draft", user: @agent,
                                        task: @task, anchor_creative: @document)
        changes.each_with_index { |attrs, index| set.creative_changes.create!(attrs.merge(position: index)) }
        set
      end

      def change(creative)
        { creative_id: creative.id, operation: "update", before: { "description" => "a" },
          after: { "description" => "b" } }
      end

      def change_attrs(id, parent_id)
        { creative_id: id, operation: "create", before: {}, after: { "description" => "new", "parent_id" => parent_id },
          previous_parent_id: parent_id }
      end
    end
  end
end

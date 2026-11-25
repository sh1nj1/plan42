require "test_helper"

module Collavre
  module AiAgent
    class CreativeQuoteContextTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:ai_bot)
        @document = Creative.create!(description: "<p>Document</p>", user: @user)
        @section = Creative.create!(description: "<p>Intro</p>", user: @user, parent: @document)
        @child = Creative.create!(description: "<p>Before the target phrase and after it</p>", user: @user,
                                  parent: @section)
        @topic = Topic.create!(creative: @document, user: @user, name: "Doc chat")
      end

      test "a review names the creative, the edit scope and where the selection is" do
        comment = quote(review_type: nil, text: "target   phrase")
        text = CreativeQuoteContext.new(comment).text

        assert_includes text, I18n.t("collavre.ai_agent.creative_quote.review", id: @section.id, title: "Intro")
        assert_includes text, "##{@child.id}"
        assert_includes text, "…Before the «target phrase» and after it…"
      end

      test "a question tells the agent writes are disabled" do
        comment = quote(review_type: :question, text: "Intro")
        text = CreativeQuoteContext.new(comment).text

        assert_includes text, I18n.t("collavre.ai_agent.creative_quote.question", id: @section.id, title: "Intro")
        assert_includes text, "«Intro»"
      end

      test "a selection that cannot be found leaves the location out" do
        assert_not_includes CreativeQuoteContext.new(quote(review_type: nil, text: "missing")).text, "«"
        assert_not_includes CreativeQuoteContext.new(quote(review_type: nil, text: "")).text, "«"
      end

      test "prepend_to leaves messages without a creative quote untouched" do
        plain = Comment.create!(creative: @document, topic: @topic, user: @user, content: "hi", skip_dispatch: true)

        assert_equal "body", CreativeQuoteContext.prepend_to("body", plain)
        assert_equal "body", CreativeQuoteContext.prepend_to("body", nil)
        assert CreativeQuoteContext.prepend_to("body", quote(review_type: nil, text: "Intro")).end_with?("\n\nbody")
      end

      test "the native trigger message carries the quote context" do
        comment = quote(review_type: :question, text: "Intro")
        context = { "comment" => { "id" => comment.id, "content" => comment.content },
                    "creative" => { "id" => @document.id }, "topic" => { "id" => @topic.id } }

        messages = MessageBuilder.new(agent: @agent, context: context, original_comment: comment).build[:messages]

        trigger = messages.find { |m| m[:kind] == :trigger }
        assert_includes trigger[:parts].first[:text], I18n.t("collavre.ai_agent.creative_quote.question",
                                                            id: @section.id, title: "Intro")
      end

      test "a Claude Channel dispatch carries the quote context" do
        comment = quote(review_type: nil, text: "Intro")
        context = { "comment" => { "id" => comment.id, "content" => comment.content },
                    "creative" => { "id" => @document.id }, "topic" => { "id" => @topic.id } }

        content = ClaudeChannelAdapter.new(agent: @agent, context: context).send(:trigger_content)

        assert content.start_with?(CreativeQuoteContext.new(comment).text)
        assert content.end_with?(comment.content)
      end

      private

      def quote(review_type:, text:)
        Comment.create!(creative: @document, topic: @topic, user: @user, content: "> #{text}\n\nPlease",
                        quoted_creative: @section, quoted_text: text, review_type: review_type, skip_dispatch: true)
      end
    end
  end
end

require "test_helper"

module Collavre
  class CommentCreativeQuoteTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @document = Creative.create!(description: "<p>Document</p>", user: @user)
      @section = Creative.create!(description: "<p>Section</p>", user: @user, parent: @document)
      @topic = Topic.create!(creative: @document, user: @user, name: "Doc chat")
    end

    test "review and question predicates follow review_type" do
      review = quote(review_type: nil)
      question = quote(review_type: :question)

      assert review.creative_quote?
      assert review.creative_review_message?
      assert_not review.creative_question_message?
      assert question.creative_question_message?
      assert_not question.creative_review_message?
      # A creative quote is not a chat-message review: ReviewHandler stays out.
      assert_not review.review_message?
    end

    test "a message quotes either a comment or a creative" do
      quoted = Comment.create!(creative: @document, topic: @topic, user: @user, content: "x", skip_dispatch: true)
      comment = Comment.new(creative: @document, topic: @topic, user: @user, content: "both",
                            quoted_comment: quoted, quoted_creative: @section)

      assert_not comment.valid?
      assert_includes comment.errors[:base], I18n.t("collavre.comments.creative_quote.single_target")

      saved = quote(review_type: nil)
      assert_raises(ActiveRecord::StatementInvalid) do
        Comment.where(id: saved.id).update_all(quoted_comment_id: quoted.id)
      end
    end

    test "document quotes run as their own agent turn" do
      plain = Comment.create!(creative: @document, topic: @topic, user: @user, content: "plain", skip_dispatch: true)
      review = quote(review_type: nil)
      question = quote(review_type: :question)

      assert_equal [ review.id, question.id ].sort, Comment.own_turn_message_ids([ plain.id, review.id, question.id, nil ]).sort
      assert_equal [], Comment.own_turn_message_ids([])
      assert_empty Comment.review_message_ids([ review.id, question.id ])
    end

    test "deleting the quoted creative keeps the message" do
      comment = quote(review_type: nil)
      @section.destroy!

      assert_nil comment.reload.quoted_creative_id
    end

    private

    def quote(review_type:)
      Comment.create!(creative: @document, topic: @topic, user: @user, content: "> Section", quoted_creative: @section,
                      quoted_text: "Section", review_type: review_type, skip_dispatch: true)
    end
  end
end

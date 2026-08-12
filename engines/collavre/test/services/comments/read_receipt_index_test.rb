# frozen_string_literal: true

require "test_helper"

module Collavre
  module Comments
    # The index resolves read receipts against the rendered window instead of the
    # creative's entire comment history. The interesting cases are all at the
    # window's edges, where "read up to here" and "read past this page" have to
    # stay distinguishable without loading everything in between.
    class ReadReceiptIndexTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @reader = users(:two)
        @creative = Creative.create!(user: @owner, description: "Receipts", sequence: 950)
      end

      test "a receipt lands on the comment the pointer names" do
        first = comment("one")
        second = comment("two")
        third = comment("three")
        point_at(second)

        assert_equal({ second.id => [ @reader ] }, receipts_for([ first, second, third ]))
      end

      # The whole reason the mapping cannot just look the pointer up directly.
      test "a pointer at a private comment falls back to the public one before it" do
        public_comment = comment("public")
        private_comment = comment("secret", private: true)
        later = comment("later")
        point_at(private_comment)

        assert_equal({ public_comment.id => [ @reader ] }, receipts_for([ public_comment, private_comment, later ]))
      end

      test "a pointer older than the window produces no receipt on this page" do
        old = comment("old")
        window = [ comment("a"), comment("b") ]
        point_at(old)

        assert_empty receipts_for(window)
      end

      # Without the one-id lookahead past the window, this reader would be shown
      # at the bottom of every page of older history they had already scrolled past.
      test "a pointer newer than the window produces no receipt on this page" do
        window = [ comment("a"), comment("b") ]
        newer = comment("c")
        point_at(newer)

        assert_empty receipts_for(window)
      end

      test "a pointer at a private comment after the window produces no receipt on this page" do
        window = [ comment("a"), comment("b") ]
        newer_private = comment("secret", private: true)
        point_at(newer_private)

        assert_empty receipts_for(window)
      end

      test "a pointer at the newest comment of all lands on it" do
        first = comment("a")
        last = comment("b")
        point_at(last)

        assert_equal({ last.id => [ @reader ] }, receipts_for([ first, last ]))
      end

      # A topic filter can hide a public comment that sits between two rendered
      # ones. A pointer on the hidden comment belongs to it, not to its neighbour.
      test "a pointer at a public comment the page filtered out produces no receipt" do
        topic = Topic.create!(creative: @creative, name: "Side", user: @owner)
        first = comment("a")
        hidden = comment("hidden", topic: topic)
        last = comment("b")
        point_at(hidden)

        assert_empty receipts_for([ first, last ])
      end

      test "topic pointers only render receipts in their own topic" do
        first_topic = Topic.create!(creative: @creative, name: "First", user: @owner)
        second_topic = Topic.create!(creative: @creative, name: "Second", user: @owner)
        first = comment("first", topic: first_topic)
        second = comment("second", topic: second_topic)
        CommentReadPointer.create!(user: @reader, creative: @creative, topic: second_topic, last_read_comment_id: second.id)

        assert_equal({ second.id => [ @reader ] }, receipts_for([ first, second ]))
      end

      test "legacy and topic pointers render their different receipts" do
        first_topic = Topic.create!(creative: @creative, name: "First", user: @owner)
        second_topic = Topic.create!(creative: @creative, name: "Second", user: @owner)
        first = comment("first", topic: first_topic)
        second = comment("second", topic: second_topic)
        CommentReadPointer.create!(user: @reader, creative: @creative, last_read_comment_id: second.id)
        CommentReadPointer.create!(user: @reader, creative: @creative, topic: first_topic, last_read_comment_id: first.id)

        assert_equal({ first.id => [ @reader ], second.id => [ @reader ] }, receipts_for([ first, second ]))
      end

      test "a legacy pointer still renders a topic-less comment for a reader with topic pointers" do
        topic = Topic.create!(creative: @creative, name: "Named", user: @owner)
        legacy = comment("legacy")
        legacy.update_column(:topic_id, nil)
        named = comment("named", topic: topic)

        CommentReadPointer.create!(user: @reader, creative: @creative, last_read_comment_id: legacy.id)
        CommentReadPointer.create!(user: @reader, creative: @creative, topic: topic, last_read_comment_id: named.id)

        assert_equal({ legacy.id => [ @reader ], named.id => [ @reader ] }, receipts_for([ legacy, named ]))
      end

      test "a legacy pointer does not override a named topic pointer" do
        topic = Topic.create!(creative: @creative, name: "Named", user: @owner)
        legacy = comment("legacy")
        first = comment("first", topic: topic)
        second = comment("second", topic: topic)

        CommentReadPointer.create!(user: @reader, creative: @creative, last_read_comment_id: second.id)
        CommentReadPointer.create!(user: @reader, creative: @creative, topic: topic, last_read_comment_id: first.id)

        assert_equal({ legacy.id => [ @reader ], first.id => [ @reader ] }, receipts_for([ legacy, first, second ]))
      end

      test "duplicate legacy and topic receipts render one avatar" do
        topic = Topic.create!(creative: @creative, name: "Named", user: @owner)
        named = comment("named", topic: topic)

        CommentReadPointer.create!(user: @reader, creative: @creative, last_read_comment_id: named.id)
        CommentReadPointer.create!(user: @reader, creative: @creative, topic: topic, last_read_comment_id: named.id)

        assert_equal({ named.id => [ @reader ] }, receipts_for([ named ]))
      end

      test "several readers on the same comment are grouped" do
        first = comment("a")
        second = comment("b")
        point_at(second)
        point_at(second, user: @owner)

        result = receipts_for([ first, second ])

        assert_equal [ second.id ], result.keys
        assert_equal [ @owner, @reader ].map(&:id).sort, result[second.id].map(&:id).sort
      end

      test "a page with no public comments has no receipts" do
        private_comment = comment("secret", private: true)
        point_at(private_comment)

        assert_empty receipts_for([ private_comment ])
      end

      test "an empty page has no receipts" do
        comment("a")

        assert_empty receipts_for([])
      end

      test "a pointer with no last read comment is ignored" do
        first = comment("a")
        CommentReadPointer.create!(user: @reader, creative: @creative, last_read_comment_id: nil)

        assert_empty receipts_for([ first ])
      end

      private

      def receipts_for(comments)
        ReadReceiptIndex.new(creative: @creative, comments: comments).receipts
      end

      def comment(content, private: false, topic: nil)
        Comment.create!(creative: @creative, user: @owner, content: content, private: private, topic: topic)
      end

      def point_at(target, user: @reader)
        CommentReadPointer.create!(user: user, creative: @creative, last_read_comment_id: target.id)
      end
    end
  end
end

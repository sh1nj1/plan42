require "test_helper"

module Creatives
  # Each origin carries its own read watermark, so the batched unread count is an
  # OR of per-origin thresholds rather than one shared cutoff. Getting that wrong
  # silently shows every user the wrong badge, so pin the arithmetic.
  class CommentBadgeIndexTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @author = users(:two)
      @index = Collavre::Creatives::CommentBadgeIndex.new(user: @user)
    end

    test "counts only visible comments newer than the read watermark" do
      creative = Creative.create!(user: @user, description: "Watermarked", sequence: 900)
      first = comment_on(creative, "one")
      comment_on(creative, "two")
      comment_on(creative, "three")
      Comment.create!(creative: creative, user: @user, content: "private", private: true)

      CommentReadPointer.create!(user: @user, creative: creative, last_read_comment_id: first.id)

      @index.index([ creative.reload ])

      assert_equal 3, @index.unread_count_for(creative), "two public comments and the user's private comment follow the watermark"
    end

    test "without a read pointer every comment is unread" do
      creative = Creative.create!(user: @user, description: "Never opened", sequence: 901)
      comment_on(creative, "one")
      comment_on(creative, "two")

      @index.index([ creative.reload ])

      assert_equal 2, @index.unread_count_for(creative)
    end

    test "does not count another user's private comments" do
      creative = Creative.create!(user: @user, description: "Private visibility", sequence: 910)
      comment_on(creative, "public")
      comment_on(creative, "private", private: true)

      @index.index([ creative.reload ])

      assert_equal 1, @index.unread_count_for(creative)
      assert @index.visible_comments?(creative)
    end

    test "each user gets their own private visibility" do
      creative = Creative.create!(user: @user, description: "Batch visibility", sequence: 911)
      shared_user = User.create!(email: "badge-shared@example.com", password: TEST_PASSWORD, name: "Badge Shared")
      CreativeShare.create!(creative: creative, user: shared_user, shared_by: @user, permission: :feedback)
      comment_on(creative, "public")
      Comment.create!(creative: creative, user: @user, content: "owner private", private: true)
      Comment.create!(creative: creative, user: shared_user, content: "shared private", private: true)

      owner_index = Collavre::Creatives::CommentBadgeIndex.new(user: @user)
      shared_index = Collavre::Creatives::CommentBadgeIndex.new(user: shared_user)
      owner_index.index([ creative ])
      shared_index.index([ creative ])

      assert_equal 2, owner_index.unread_count_for(creative)
      assert_equal 2, shared_index.unread_count_for(creative)
      assert owner_index.visible_comments?(creative)
      assert shared_index.visible_comments?(creative)
    end

    test "a watermark at the newest comment leaves nothing unread" do
      creative = Creative.create!(user: @user, description: "Fully read", sequence: 902)
      comment_on(creative, "one")
      last = comment_on(creative, "two")

      CommentReadPointer.create!(user: @user, creative: creative, last_read_comment_id: last.id)

      @index.index([ creative.reload ])

      assert_equal 0, @index.unread_count_for(creative)
    end

    # The batch is one query for the whole level, so a per-origin watermark must
    # not leak across origins.
    test "each origin is counted against its own watermark" do
      read = Creative.create!(user: @user, description: "Read", sequence: 903)
      read_first = comment_on(read, "a1")
      comment_on(read, "a2")
      CommentReadPointer.create!(user: @user, creative: read, last_read_comment_id: read_first.id)

      unread = Creative.create!(user: @user, description: "Unread", sequence: 904)
      comment_on(unread, "b1")
      comment_on(unread, "b2")
      comment_on(unread, "b3")

      fully_read = Creative.create!(user: @user, description: "Caught up", sequence: 905)
      caught_up = comment_on(fully_read, "c1")
      CommentReadPointer.create!(user: @user, creative: fully_read, last_read_comment_id: caught_up.id)

      @index.index([ read.reload, unread.reload, fully_read.reload ])

      assert_equal 1, @index.unread_count_for(read)
      assert_equal 3, @index.unread_count_for(unread)
      assert_equal 0, @index.unread_count_for(fully_read)
    end

    # nil, not 0 — the caller has to be able to tell "not batched" from "nothing
    # unread", or an un-indexed node would quietly render an empty badge.
    test "an unindexed creative reports nil" do
      creative = Creative.create!(user: @user, description: "Untouched", sequence: 906)

      assert_nil @index.unread_count_for(creative)
    end

    # Presence suppression is applied here, not by the caller: it is a cache read
    # per origin, so it has to ride along with the batch. The count handed out is
    # the one the badge renders.
    test "a user with the chat open sees nothing unread" do
      creative = Creative.create!(user: @user, description: "Watching", sequence: 907)
      comment_on(creative, "one")
      comment_on(creative, "two")

      Collavre::CommentPresenceStore.add(creative.id, @user.id)

      @index.index([ creative.reload ])

      assert_equal 0, @index.unread_count_for(creative)
    ensure
      Rails.cache.delete(Collavre::CommentPresenceStore.key(creative.id))
    end

    test "presence of another user does not suppress our badge" do
      creative = Creative.create!(user: @user, description: "Someone else watching", sequence: 908)
      comment_on(creative, "one")

      Collavre::CommentPresenceStore.add(creative.id, @author.id)

      @index.index([ creative.reload ])

      assert_equal 1, @index.unread_count_for(creative)
    ensure
      Rails.cache.delete(Collavre::CommentPresenceStore.key(creative.id))
    end

    test "an anonymous visitor is never suppressed" do
      creative = Creative.create!(user: @user, description: "Anonymous", sequence: 909)
      comment_on(creative, "one")
      Collavre::CommentPresenceStore.add(creative.id, @user.id)

      anonymous = Collavre::Creatives::CommentBadgeIndex.new(user: nil)
      anonymous.index([ creative.reload ])

      assert_equal 1, anonymous.unread_count_for(creative)
    ensure
      Rails.cache.delete(Collavre::CommentPresenceStore.key(creative.id))
    end

    private

    def comment_on(creative, content, private: false)
      Comment.create!(creative: creative, user: @author, content: content, private: private)
    end
  end
end

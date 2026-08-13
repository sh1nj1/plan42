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

    test "can index unread counts without querying visible counts" do
      creative = Creative.create!(user: @user, description: "Tree badge", sequence: 913)
      comment_on(creative, "one")

      @index.stub(:visible_counts, ->(_) { flunk("visible counts should not be queried for a tree badge") }) do
        @index.index([ creative.reload ], include_visible_counts: false)
      end

      assert_equal 1, @index.unread_count_for(creative)
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

    test "groups visible unread comments by topic using the creative read pointer" do
      creative = Creative.create!(user: @user, description: "Topic badges", sequence: 914)
      first_topic = creative.topics.create!(name: "First", user: @user)
      second_topic = creative.topics.create!(name: "Second", user: @user)
      read_comment = Comment.create!(creative: creative, topic: first_topic, user: @author, content: "read")
      Comment.create!(creative: creative, topic: first_topic, user: @author, content: "unread")
      Comment.create!(creative: creative, topic: second_topic, user: @user, content: "private", private: true)
      Comment.create!(creative: creative, topic: second_topic, user: @author, content: "hidden", private: true)
      CommentReadPointer.create!(user: @user, creative: creative, last_read_comment_id: read_comment.id)

      assert_equal({ first_topic.id => 1, second_topic.id => 1 }, @index.unread_counts_by_topic(creative))
    end

    test "uses a topic pointer without clearing unread comments in another topic" do
      creative = Creative.create!(user: @user, description: "Independent topic badges", sequence: 916)
      first_topic = creative.topics.create!(name: "First", user: @user)
      second_topic = creative.topics.create!(name: "Second", user: @user)
      first = Comment.create!(creative: creative, topic: first_topic, user: @author, content: "first")
      Comment.create!(creative: creative, topic: second_topic, user: @author, content: "second")
      CommentReadPointer.create!(user: @user, creative: creative, topic: first_topic, last_read_comment_id: first.id)

      assert_equal({ second_topic.id => 1 }, @index.unread_counts_by_topic(creative))
      @index.index([ creative ])
      assert_equal 1, @index.unread_count_for(creative)
    end

    test "suppresses topic unread counts while the user is present" do
      creative = Creative.create!(user: @user, description: "Present topic badges", sequence: 915)
      topic = creative.topics.create!(name: "Updates", user: @user)
      Comment.create!(creative: creative, topic: topic, user: @author, content: "unread")
      Collavre::CommentPresenceStore.add(creative.id, @user.id)
      Collavre::CommentPresenceStore.set_topic(creative.id, @user.id, topic.id)

      assert_empty @index.unread_counts_by_topic(creative)
    ensure
      Rails.cache.delete(Collavre::CommentPresenceStore.key(creative.id))
      Rails.cache.delete(Collavre::CommentPresenceStore.topic_key(creative.id, @user.id))
    end

    test "suppresses active topic counts while the user is viewing All Messages" do
      creative = Creative.create!(user: @user, description: "All Messages badges", sequence: 914)
      active_topic = creative.topics.create!(name: "Active", user: @user)
      archived_topic = creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
      Comment.create!(creative: creative, user: @author, content: "main")
      Comment.create!(creative: creative, topic: active_topic, user: @author, content: "active")
      Comment.create!(creative: creative, topic: archived_topic, user: @author, content: "archived")
      CommentPresenceStore.add(creative.id, @user.id)
      CommentPresenceStore.set_topic(creative.id, @user.id, nil, rendered_topic_ids: [ creative.main_topic.id, active_topic.id ])

      assert_equal({ archived_topic.id => 1 }, @index.unread_counts_by_topic(creative))
      @index.index([ creative ])
      assert_equal 1, @index.unread_count_for(creative)
    ensure
      Rails.cache.delete(CommentPresenceStore.key(creative.id))
      Rails.cache.delete(CommentPresenceStore.topic_key(creative.id, @user.id))
    end

    test "suppresses an archived topic viewed beside All Messages" do
      creative = Creative.create!(user: @user, description: "All Messages with archived topic", sequence: 919)
      archived_topic = creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
      Comment.create!(creative: creative, topic: archived_topic, user: @author, content: "archived")
      CommentPresenceStore.add(creative.id, @user.id, subscription_id: "all")
      CommentPresenceStore.add(creative.id, @user.id, subscription_id: "archived")
      CommentPresenceStore.set_topic(creative.id, @user.id, nil, subscription_id: "all")
      CommentPresenceStore.set_topic(creative.id, @user.id, archived_topic.id, subscription_id: "archived")

      assert_equal [ CommentPresenceStore::ALL_TOPICS, archived_topic.id ], CommentPresenceStore.viewing_topics(creative.id, @user.id)
      assert_equal [ @user.id ], CommentPresenceStore.list(creative.id)
      assert_equal(
        { @user.id => [ CommentPresenceStore::ALL_TOPICS, archived_topic.id ] },
        CommentPresenceStore.viewing_topics_for(creative.id, [ @user.id ])
      )
      assert_empty @index.unread_counts_by_topic(creative)
      badge = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user ]).fetch(@user.id)
      assert_equal 0, badge.unread_count
    ensure
      CommentPresenceStore.remove(creative.id, @user.id, subscription_id: "all")
      CommentPresenceStore.remove(creative.id, @user.id, subscription_id: "archived")
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

    test "chunks a large unwatermarked level below SQLite's expression limit" do
      origins = (1..1000).map { |id| Struct.new(:id).new(id) }

      @index.index(origins)

      assert_not_nil @index.unread_count_for(origins.last)
    end

    test "batch counts private comments per recipient and watermark without double counting self-approved comments" do
      creative = Creative.create!(user: @user, description: "Private batch counts", sequence: 912)
      viewer = User.create!(email: "badge-viewer@example.com", password: TEST_PASSWORD, name: "Badge Viewer")
      first = Comment.create!(creative: creative, user: @user, content: "owner private", private: true)
      shared = Comment.create!(creative: creative, user: @user, approver: viewer, content: "shared private", private: true)
      Comment.create!(creative: creative, user: viewer, approver: viewer, content: "self-approved private", private: true)

      CommentReadPointer.create!(user: @user, creative: creative, last_read_comment_id: first.id)
      CommentReadPointer.create!(user: viewer, creative: creative, last_read_comment_id: shared.id)

      badges = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user, viewer ])

      assert_equal 1, badges.fetch(@user.id).unread_count
      assert badges.fetch(@user.id).visible_comments
      assert_equal 1, badges.fetch(viewer.id).unread_count
      assert badges.fetch(viewer.id).visible_comments
    end

    test "fanout batches topic pointers without rebuilding an index for each recipient" do
      creative = Creative.create!(user: @user, description: "Batched topic fanout", sequence: 917)
      topic = creative.topics.create!(name: "Updates", user: @user)
      viewer = User.create!(email: "topic-badge-viewer@example.com", password: TEST_PASSWORD, name: "Topic Badge Viewer")
      first = Comment.create!(creative: creative, topic: topic, user: @author, content: "read")
      Comment.create!(creative: creative, topic: topic, user: @author, content: "unread")
      Comment.create!(creative: creative, topic: topic, user: @user, content: "owner private", private: true)
      CommentReadPointer.create!(user: @user, creative: creative, topic: topic, last_read_comment_id: first.id)

      Collavre::Creatives::CommentBadgeIndex.stub(:new, ->(*) { flunk("fanout must not build a per-user index") }) do
        badges = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user, viewer ])

        assert_equal 2, badges.fetch(@user.id).unread_count
        assert_equal 2, badges.fetch(viewer.id).unread_count
      end
    end

    test "fanout scans public comment history without joining it to recipients" do
      creative = Creative.create!(user: @user, description: "Non-fanout public history", sequence: 925)
      viewers = 3.times.map do |index|
        User.create!(email: "public-badge-viewer-#{index}@example.com", password: TEST_PASSWORD, name: "Public Badge Viewer #{index}")
      end
      comment_on(creative, "public")
      comment_queries = []

      callback = ->(_name, _started, _finished, _id, payload) {
        sql = payload[:sql]
        comment_queries << sql if sql.include?(%q(FROM "comments"))
      }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: viewers)
      end

      assert_equal 1, comment_queries.length
      assert_no_match(/JOIN/i, comment_queries.first)
    end

    test "fanout keeps archived-topic counts while a recipient views All Messages" do
      creative = Creative.create!(user: @user, description: "All Messages fanout", sequence: 918)
      active_topic = creative.topics.create!(name: "Active", user: @user)
      archived_topic = creative.topics.create!(name: "Archived", user: @user, archived_at: Time.current)
      Comment.create!(creative: creative, user: @author, content: "main")
      Comment.create!(creative: creative, topic: active_topic, user: @author, content: "active")
      Comment.create!(creative: creative, topic: archived_topic, user: @author, content: "archived")
      CommentPresenceStore.add(creative.id, @user.id)
      CommentPresenceStore.set_topic(creative.id, @user.id, nil, rendered_topic_ids: [ creative.main_topic.id, active_topic.id ])

      badge = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user ]).fetch(@user.id)

      assert_equal 1, badge.unread_count
      assert badge.visible_comments
    ensure
      Rails.cache.delete(CommentPresenceStore.key(creative.id))
      Rails.cache.delete(CommentPresenceStore.topic_key(creative.id, @user.id))
    end

    test "All Messages keeps a topic restored after its rendered snapshot unread" do
      creative = Creative.create!(user: @user, description: "Restored topic snapshot", sequence: 920)
      rendered_topic = creative.topics.create!(name: "Rendered", user: @user)
      restored_topic = creative.topics.create!(name: "Restored", user: @user, archived_at: Time.current)
      Comment.create!(creative: creative, topic: rendered_topic, user: @author, content: "rendered")
      Comment.create!(creative: creative, topic: restored_topic, user: @author, content: "unseen")
      CommentPresenceStore.set_topic(creative.id, @user.id, nil, rendered_topic_ids: [ rendered_topic.id ])
      restored_topic.update!(archived_at: nil)

      assert_equal({ restored_topic.id => 1 }, @index.unread_counts_by_topic(creative))
      badge = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user ]).fetch(@user.id)
      assert_equal 1, badge.unread_count
    ensure
      CommentPresenceStore.remove(creative.id, @user.id)
    end

    test "All Messages keeps an unrendered legacy lane unread" do
      creative = Creative.create!(user: @user, description: "Legacy snapshot", sequence: 921)
      rendered_topic = creative.topics.create!(name: "Rendered", user: @user)
      legacy_comment = Comment.create!(creative: creative, user: @author, content: "unseen legacy")
      legacy_comment.update_column(:topic_id, nil)
      Comment.create!(creative: creative, topic: rendered_topic, user: @author, content: "rendered")
      CommentPresenceStore.set_topic(creative.id, @user.id, nil, rendered_topic_ids: [ rendered_topic.id ])

      assert_equal({ nil => 1 }, @index.unread_counts_by_topic(creative))
      badge = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user ]).fetch(@user.id)
      assert_equal 1, badge.unread_count
    ensure
      CommentPresenceStore.remove(creative.id, @user.id)
    end

    test "All Messages suppresses a rendered legacy lane" do
      creative = Creative.create!(user: @user, description: "Rendered legacy snapshot", sequence: 922)
      legacy_comment = Comment.create!(creative: creative, user: @author, content: "rendered legacy")
      legacy_comment.update_column(:topic_id, nil)
      CommentPresenceStore.set_topic(creative.id, @user.id, nil, rendered_legacy_topic: true)

      assert_empty @index.unread_counts_by_topic(creative)
      badge = Collavre::Creatives::CommentBadgeIndex.for_users(origin: creative, users: [ @user ]).fetch(@user.id)
      assert_equal 0, badge.unread_count
    ensure
      CommentPresenceStore.remove(creative.id, @user.id)
    end

    # nil, not 0 — the caller has to be able to tell "not batched" from "nothing
    # unread", or an un-indexed node would quietly render an empty badge.
    test "an unindexed creative reports nil" do
      creative = Creative.create!(user: @user, description: "Untouched", sequence: 906)

      assert_nil @index.unread_count_for(creative)
    end

    test "a user viewing a topic does not count that topic as unread" do
      creative = Creative.create!(user: @user, description: "Watching", sequence: 907)
      comment_on(creative, "one")
      comment_on(creative, "two")

      Collavre::CommentPresenceStore.add(creative.id, @user.id)
      Collavre::CommentPresenceStore.set_topic(creative.id, @user.id, creative.main_topic.id)

      @index.index([ creative.reload ])

      assert_equal 0, @index.unread_count_for(creative)
    ensure
      Rails.cache.delete(Collavre::CommentPresenceStore.key(creative.id))
      Rails.cache.delete(Collavre::CommentPresenceStore.topic_key(creative.id, @user.id))
    end

    test "batches presence topic snapshots across indexed creatives" do
      first_creative = Creative.create!(user: @user, description: "First presence batch", sequence: 923)
      second_creative = Creative.create!(user: @user, description: "Second presence batch", sequence: 924)
      comment_on(first_creative, "first")
      comment_on(second_creative, "second")
      CommentPresenceStore.add(first_creative.id, @user.id)
      CommentPresenceStore.add(second_creative.id, @user.id)
      CommentPresenceStore.set_topic(first_creative.id, @user.id, first_creative.main_topic.id)
      CommentPresenceStore.set_topic(second_creative.id, @user.id, second_creative.main_topic.id)

      requested_origin_ids = nil
      CommentPresenceStore.stub(:viewing_topics_for_creatives, ->(user_id, origin_ids) {
        requested_origin_ids = origin_ids
        assert_equal @user.id, user_id
        {
          first_creative.id => [ first_creative.main_topic.id ],
          second_creative.id => [ second_creative.main_topic.id ]
        }
      }) do
        CommentPresenceStore.stub(:viewing_topics, ->(*) { flunk("indexed creatives must use the batch presence lookup") }) do
          @index.index([ first_creative, second_creative ])
        end
      end

      assert_equal [ first_creative.id, second_creative.id ], requested_origin_ids
      assert_equal 0, @index.unread_count_for(first_creative)
      assert_equal 0, @index.unread_count_for(second_creative)
    ensure
      CommentPresenceStore.remove(first_creative.id, @user.id) if first_creative
      CommentPresenceStore.remove(second_creative.id, @user.id) if second_creative
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

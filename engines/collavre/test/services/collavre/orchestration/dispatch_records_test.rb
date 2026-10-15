# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class DispatchRecordsTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @topic = Topic.create!(name: "Records", creative: @creative, user: @user)
      end

      test "find reads a record once" do
        records = DispatchRecords.new

        first = nil
        assert_queries_match(/FROM "topics"/, count: 1) do
          first = records.find(Topic, @topic.id)
          assert_same first, records.find(Topic, @topic.id.to_s)
        end
        assert_equal @topic, first
      end

      test "find remembers a missing record" do
        records = DispatchRecords.new

        assert_queries_match(/FROM "topics"/, count: 1) do
          assert_nil records.find(Topic, -1)
          assert_nil records.find(Topic, -1)
        end
      end

      test "find returns nil for a blank id without a query" do
        assert_no_queries_match(/SELECT/) do
          assert_nil DispatchRecords.new.find(Topic, nil)
          assert_nil DispatchRecords.new.find(Topic, "")
        end
      end

      test "find keys records by class" do
        records = DispatchRecords.new.seed(@topic)

        other = records.find(Creative, @topic.id)
        assert other.nil? || other.is_a?(Creative)
        assert_same @topic, records.find(Topic, @topic.id)
      end

      test "seed ignores nil and unsaved records" do
        unsaved = Topic.new(name: "Unsaved", creative: @creative, user: @user)
        records = DispatchRecords.new.seed(nil).seed(unsaved)

        assert_queries_match(/FROM "topics"/, count: 1) do
          assert_equal @topic, records.find(Topic, @topic.id)
        end
      end

      test "separate instances share nothing" do
        first = DispatchRecords.new
        cached = first.find(Topic, @topic.id)
        @topic.update!(primary_agent_id: users(:ai_bot).id)

        assert_nil cached.primary_agent_id
        assert_equal users(:ai_bot).id, DispatchRecords.new.find(Topic, @topic.id).primary_agent_id
      end

      test "for_comment seeds the comment and its loaded author" do
        comment = Comment.create!(creative: @creative, topic: @topic, user: @user, content: "hello", skip_dispatch: true)
        records = DispatchRecords.for_comment(comment)

        assert_no_queries_match(/SELECT/) do
          assert_same comment, records.find(Comment, comment.id)
          assert_same comment.user, records.find(User, @user.id)
        end
      end

      test "for_comment does not load an author the comment has not read" do
        comment = Comment.create!(creative: @creative, topic: @topic, user: @user, content: "hello", skip_dispatch: true)
        fresh = Comment.find(comment.id)

        records = nil
        assert_no_queries_match(/SELECT/) { records = DispatchRecords.for_comment(fresh) }
        assert_queries_match(/FROM "users"/, count: 1) do
          assert_equal @user, records.find(User, @user.id)
        end
      end
    end
  end
end

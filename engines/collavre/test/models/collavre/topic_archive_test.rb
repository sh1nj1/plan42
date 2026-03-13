# frozen_string_literal: true

require "test_helper"

module Collavre
  class TopicArchiveTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user

      @creative = Creative.create!(description: "Test Creative", user: @user)
      @topic1 = Topic.create!(name: "Active Topic", creative: @creative, user: @user)
      @topic2 = Topic.create!(name: "To Archive", creative: @creative, user: @user)
    end

    test "active scope returns non-archived topics" do
      @topic2.archive!
      active = @creative.topics.active
      assert_includes active, @topic1
      assert_not_includes active, @topic2
    end

    test "archived scope returns archived topics" do
      @topic2.archive!
      archived = @creative.topics.archived
      assert_includes archived, @topic2
      assert_not_includes archived, @topic1
    end

    test "archive! sets archived_at" do
      assert_nil @topic2.archived_at
      @topic2.archive!
      assert @topic2.archived?
      assert_not_nil @topic2.archived_at
    end

    test "unarchive! clears archived_at" do
      @topic2.archive!
      assert @topic2.archived?
      @topic2.unarchive!
      assert_not @topic2.archived?
      assert_nil @topic2.archived_at
    end
  end
end

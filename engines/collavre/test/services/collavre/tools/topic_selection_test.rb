# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicSelectionTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @stranger = users(:two)
        @creative = Collavre::Creative.create!(description: "Selection Host", user: @user)
        @a = @creative.topics.create!(name: "A", user: @user)
        @b = @creative.topics.create!(name: "B", user: @user)
      end

      test "accepts every id shape an agent is likely to write" do
        assert_equal [ 1, 2, 3 ], IdList.parse("1,2,3")
        assert_equal [ 1, 2 ], IdList.parse([ "1", 2 ])
        assert_equal [ 5 ], IdList.parse(5)
        assert_equal [ 5 ], IdList.parse("5")
        assert_equal [ 1, 2 ], IdList.parse(" 1 , 2 , ")
      end

      test "deduplicates and returns nothing for blank input" do
        assert_equal [ 7 ], IdList.parse("7,7")
        assert_empty IdList.parse(nil)
        assert_empty IdList.parse("")
        assert_empty IdList.parse([ "", "  " ])
      end

      test "resolves readable topics in the order they were asked for" do
        topics, errors = TopicSelection.resolve([ @b.id, @a.id ], user: @user)

        assert_equal [ @b.id, @a.id ], topics.map(&:id)
        assert_empty errors
      end

      test "reports missing and unreadable ids identically so existence cannot be probed" do
        _, errors = TopicSelection.resolve([ 999_999 ], user: @user)
        _, denied = TopicSelection.resolve([ @a.id ], user: @stranger)

        assert_equal "Topic not found or not readable", errors.first[:error]
        assert_equal errors.first[:error], denied.first[:error]
      end

      test "one bad id does not discard the good ones" do
        topics, errors = TopicSelection.resolve([ @a.id, 999_999 ], user: @user)

        assert_equal [ @a.id ], topics.map(&:id)
        assert_equal 1, errors.size
      end
    end
  end
end

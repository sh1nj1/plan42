# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class IdListTest < ActiveSupport::TestCase
      test "accepts the shapes a model actually writes" do
        assert_equal [ 12, 45, 78 ], IdList.parse("12,45,78")
        assert_equal [ 12, 45 ], IdList.parse([ "12", 45 ])
        assert_equal [ 12 ], IdList.parse(12)
        assert_equal [ 12 ], IdList.parse("12")
        assert_equal [ 12, 45 ], IdList.parse(" 12 , 45 ")
        assert_equal [ 12 ], IdList.parse("12,12")
        assert_empty IdList.parse(nil)
        assert_empty IdList.parse(" , ")
      end

      # to_i reads "12.5" as 12 and "123oops" as 123. topic_create and
      # topic_branch move messages, so coercion moves a different message than
      # the one named and reports success — the failure the caller never sees.
      test "rejects tokens that are not whole numbers instead of coercing them" do
        [ "123oops", "12.5", "-4", "1e3", "abc", "#12" ].each do |token|
          error = assert_raises(ArgumentError, "expected #{token.inspect} to be rejected") do
            IdList.parse(token)
          end
          assert_match(/not a valid id/, error.message)
        end
      end

      test "rejects a malformed token even when the rest of the list is valid" do
        assert_raises(ArgumentError) { IdList.parse("12,oops,45") }
      end
    end
  end
end

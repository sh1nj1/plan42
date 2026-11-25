require "test_helper"

module Collavre
  class SuccessfulAuthenticationTest < ActiveSupport::TestCase
    class LoginHarness
      include SuccessfulAuthentication
      attr_reader :session, :calls

      def initialize(return_to)
        @session = { return_to_after_authenticating: return_to, untrusted: "discard" }
        @calls = []
      end

      def reset_session
        @calls << :reset
        @session = {}
      end

      def start_new_session_for(user)
        @calls << [ :start, user, session.dup ]
      end

      public :rotate_session_for
    end

    test "clears pre-login state before starting the session and preserves return target" do
      harness = LoginHarness.new("/creatives/42")
      harness.rotate_session_for(:user)
      expected = { return_to_after_authenticating: "/creatives/42" }
      assert_equal expected, harness.session
      assert_equal [ :reset, [ :start, :user, expected ] ], harness.calls
    end

    test "does not restore an absent return target" do
      harness = LoginHarness.new(nil)
      harness.rotate_session_for(:user)
      assert_empty harness.session
      assert_equal [ :reset, [ :start, :user, {} ] ], harness.calls
    end
  end
end

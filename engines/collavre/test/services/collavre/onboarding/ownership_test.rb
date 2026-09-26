# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class OwnershipTest < ActiveSupport::TestCase
      test "normalizes legacy data before stamping an item" do
        assert_equal({}, Ownership.metadata(nil))
        creative = Creative.create!(user: users(:one), description: "Legacy", data: "legacy")
        assert_equal({}, Ownership.metadata(creative))
        Ownership.stamp!(creative, "session")
        assert Ownership.owned?(creative.reload)
      end

      test "rejects tampered and transferred ownership" do
        creative = Creative.create!(user: users(:one), description: "Practice")
        Ownership.stamp!(creative, "session")
        metadata = creative.data.deep_dup
        creative.data["onboarding"]["session_id"] = "other-session"
        refute Ownership.owned?(creative)
        creative.data = metadata.deep_dup
        creative.user = users(:two)
        refute Ownership.owned?(creative)
        creative.user = users(:one)
        creative.data["onboarding"]["ownership"] = "invalid"
        refute Ownership.owned?(creative)
      end
    end
  end
end

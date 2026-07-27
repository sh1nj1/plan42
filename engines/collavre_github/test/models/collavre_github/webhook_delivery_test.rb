require_relative "../../test_helper"

module CollavreGithub
  class WebhookDeliveryTest < ActiveSupport::TestCase
    test "claim returns true the first time and false afterwards" do
      assert WebhookDelivery.claim("guid-1", event: "push")
      refute WebhookDelivery.claim("guid-1", event: "push")
    end

    test "claim allows a blank GUID through without recording it" do
      assert WebhookDelivery.claim(nil, event: "push")
      assert WebhookDelivery.claim("", event: "push")
      assert_equal 0, WebhookDelivery.count
    end

    test "claim is safe against a concurrent insert of the same GUID" do
      # Simulates the real race: two hooks deliver the same GUID and both pass
      # the uniqueness check before either commits. The DB index is what makes
      # exactly one of them win.
      WebhookDelivery.create!(delivery_guid: "racy", created_at: Time.current)
      refute WebhookDelivery.claim("racy", event: "pull_request")
    end

    test "prune! removes rows past the retention window and keeps recent ones" do
      WebhookDelivery.create!(delivery_guid: "old", created_at: (WebhookDelivery::RETENTION + 1.day).ago)
      WebhookDelivery.create!(delivery_guid: "fresh", created_at: 1.hour.ago)

      assert_equal 1, WebhookDelivery.prune!
      assert_equal [ "fresh" ], WebhookDelivery.pluck(:delivery_guid)
    end

    test "a pruned GUID can be claimed again" do
      WebhookDelivery.create!(delivery_guid: "recycled", created_at: (WebhookDelivery::RETENTION + 1.day).ago)
      WebhookDelivery.prune!

      assert WebhookDelivery.claim("recycled", event: "push")
    end
  end
end

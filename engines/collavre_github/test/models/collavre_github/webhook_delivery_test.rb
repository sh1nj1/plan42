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

    test "a takeover issues a token distinct from the one it supersedes" do
      original = supersede("token-swap")

      assert original.present?
      refute_equal original, WebhookDelivery.claim("token-swap", event: "push")
    end

    # Ownership is not permanent: a run slower than STALE_CLAIM_AFTER has its
    # claim taken over. Acting on the GUID alone from that point reaches past
    # this run's own claim and into the one that replaced it.
    test "a superseded run cannot release the claim that replaced it" do
      original = supersede("slow-run")
      replacement = WebhookDelivery.claim("slow-run", event: "push")
      assert replacement, "the stale claim should have been taken over"

      WebhookDelivery.release("slow-run", original)

      assert WebhookDelivery.exists?(delivery_guid: "slow-run"),
        "the replacement's claim must survive the superseded run's cleanup"
      refute WebhookDelivery.claim("slow-run", event: "push"),
        "a third delivery must not be able to claim while the replacement is still running"
    end

    test "a superseded run cannot mark the replacement's claim processed" do
      original = supersede("slow-run-2")
      replacement = WebhookDelivery.claim("slow-run-2", event: "push")

      WebhookDelivery.mark_processed!("slow-run-2", original)
      assert_nil WebhookDelivery.find_by(delivery_guid: "slow-run-2").processed_at,
        "the replacement has not finished, so nothing may stamp its claim processed"

      WebhookDelivery.mark_processed!("slow-run-2", replacement)
      assert_not_nil WebhookDelivery.find_by(delivery_guid: "slow-run-2").processed_at
    end

    test "release still drops the claim of the run that owns it" do
      token = WebhookDelivery.claim("owned", event: "push")

      WebhookDelivery.release("owned", token)

      refute WebhookDelivery.exists?(delivery_guid: "owned")
    end

    private

    # Claims `guid` and ages the claim past the takeover window, returning the
    # token of the run about to be superseded.
    def supersede(guid)
      token = WebhookDelivery.claim(guid, event: "push")
      WebhookDelivery
        .where(delivery_guid: guid)
        .update_all(created_at: (WebhookDelivery::STALE_CLAIM_AFTER + 1.minute).ago)
      token
    end
  end
end

# frozen_string_literal: true

module CollavreLinear
  # Suppresses echo loops that arise when our own webhook events bounce back.
  #
  # PRIMARY (and only active) guard: compare the webhook `actor.id` against
  # `account.app_actor_id`.  When `app_actor_id` is nil the check returns false
  # (conservative — no suppression), so the guard is a no-op until the account
  # is fully provisioned.
  #
  # `last_outbound_at` is written by record_outbound for observability and as a
  # hook for future guards, but it is NOT currently read by any suppression
  # logic.
  module EchoGuard
    # Returns true when the webhook payload was triggered by our own app actor.
    # Safe against nil payload, missing keys, and nil app_actor_id — always
    # returns false rather than raising.
    def self.our_event?(account, payload)
      actor_id = payload&.dig("actor", "id")
      return false if actor_id.nil?

      app_actor = account.app_actor_id
      return false if app_actor.nil?

      actor_id == app_actor
    end

    # Stamps `link.last_outbound_at` to the current time for observability.
    # This is NOT an active suppression guard — it is recorded so future logic
    # can consult it without a schema change.  `linear_id` is accepted for
    # future in-flight token tracking but is not persisted in this implementation.
    def self.record_outbound(link, _linear_id = nil)
      link.update_column(:last_outbound_at, Time.current)
    end
  end
end

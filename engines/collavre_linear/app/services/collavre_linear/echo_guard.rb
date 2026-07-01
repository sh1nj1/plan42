# frozen_string_literal: true

module CollavreLinear
  # Suppresses echo loops that arise when our own webhook events bounce back.
  #
  # PRIMARY guard: compare the webhook `actor.id` against `account.app_actor_id`.
  # SECONDARY guard: `last_outbound_at` timestamp window for the brief period
  #   before `app_actor_id` is populated.
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

    # Stamps `link.last_outbound_at` to the current time (secondary guard).
    # `linear_id` is accepted for future in-flight token tracking but is not
    # persisted in this initial implementation.
    def self.record_outbound(link, _linear_id = nil)
      link.update_column(:last_outbound_at, Time.current)
    end
  end
end

# frozen_string_literal: true

# Guard solid_cable's polling thread against silent death. See
# `lib/solid_cable_listener_resilience.rb` for the failure mode this covers.
Rails.application.config.after_initialize do
  SolidCableInlineBroadcast.install! if SolidCableListenerResilience.cable_adapter == "solid_cable"
  SolidCableListenerResilience.install_if_configured!
end

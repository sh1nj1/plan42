# frozen_string_literal: true

# Keep stream updates synchronous while using Solid Cable 4.1.0.
# The upstream inline_broadcasts option arrived after this release.
module SolidCableInlineBroadcast
  def self.install!
    return unless SolidCable::VERSION == "4.1.0"

    adapter = ActionCable::SubscriptionAdapter::SolidCable
    adapter.include(SolidCable::Trimming)
    adapter.prepend(self)
  end

  def broadcast(channel, payload)
    SolidCable::Message.broadcast(channel, payload)
    trim_batches(1).times { SolidCable::TrimJob.perform_now } if SolidCable.autotrim?
  end
end

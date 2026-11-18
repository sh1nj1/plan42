# frozen_string_literal: true

# Keep stream updates synchronous on releases with batching but no inline option.
module SolidCableInlineBroadcast
  def self.install!(adapter = ActionCable::SubscriptionAdapter::SolidCable)
    return if SolidCable.respond_to?(:inline_broadcasts?)
    return unless adapter.private_method_defined?(:broadcaster)

    adapter.include(SolidCable::Trimming)
    adapter.prepend(self)
  end

  def broadcast(channel, payload)
    # This adapter patch runs before Action Cable's ChannelPrefix wrapper.
    SolidCable::Message.broadcast(channel_with_prefix(channel), payload)
    trim_batches(1).times { SolidCable::TrimJob.perform_now } if SolidCable.autotrim?
  end
end

# frozen_string_literal: true

module Collavre
  # Shared idempotent attach/reactivate lifecycle for topic channels.
  # Every channel subtype reaches the same end-state regardless of which tool
  # invoked it: a row that is active, not dismissed, and visible under the
  # `not_dismissed` render scope.
  #
  # Subtype-specific resets (e.g. PR `pr_state` back to "open" so a previously
  # merged-then-reattached channel renders the green badge again) run via the
  # `on_reactivate` proc.
  class ChannelAttacher
    # Returns [channel, status] where status ∈ :created / :reactivated / :noop.
    #
    # `lookup` is called twice in the unique-violation race path, so it must
    # be a fresh query each call (not a captured AR record).
    #
    # `on_noop` runs when the existing channel is still active+visible and we
    # would otherwise short-circuit. Preview channels use it to silently refresh
    # config (e.g. new port after a restart) so the chip link never points at a
    # dead server while reporting success.
    def self.call(channel_class:, lookup:, create_attrs:, on_reactivate: nil, on_noop: nil)
      existing = lookup.call
      if existing
        return noop(existing, on_noop) if existing.active? && existing.dismissed_at.nil?
        reactivate(existing, on_reactivate)
        return [ existing, :reactivated ]
      end
      [ channel_class.create!(create_attrs), :created ]
    rescue ActiveRecord::RecordNotUnique
      existing = lookup.call
      raise unless existing
      if existing.active? && existing.dismissed_at.nil?
        noop(existing, on_noop)
      else
        reactivate(existing, on_reactivate)
        [ existing, :reactivated ]
      end
    end

    def self.reactivate(channel, on_reactivate)
      channel.state = :active unless channel.active?
      channel.dismissed_at = nil unless channel.dismissed_at.nil?
      on_reactivate&.call(channel)
      channel.save!
    end
    private_class_method :reactivate

    def self.noop(channel, on_noop)
      if on_noop
        on_noop.call(channel)
        channel.save! if channel.changed?
      end
      [ channel, :noop ]
    end
    private_class_method :noop
  end
end

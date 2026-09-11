# frozen_string_literal: true

module CollavreGithub
  # Out-of-band PR state correction: applies the same end-state the webhook
  # would have produced when a `pull_request` event was never delivered (hook
  # added after the merge, delivery failure, repo renamed mid-flight).
  #
  # The webhook path does NOT route through here on purpose. There, `handle`
  # only *returns* the closing message and WebhooksController injects it and
  # detaches, because the controller owns the per-channel lock that also
  # de-duplicates GitHub retries. This class owns the whole transition instead,
  # so it takes the lock itself. Both paths share the message builders on
  # GithubPrChannel, which is the part that would otherwise drift.
  class PrChannelStateUpdater
    # status ∈ :updated / :noop
    Result = Struct.new(:status, :channel, :previous_state, keyword_init: true)

    def self.call(channel:, state:)
      new(channel: channel, state: state).call
    end

    def initialize(channel:, state:)
      @channel = channel
      @state = state.to_s
      unless GithubPrChannel::PR_STATES.include?(@state)
        raise ArgumentError, "Invalid pr_state: #{state.inspect}"
      end
    end

    def call
      channel.with_lock do
        previous_state = channel.pr_state
        next Result.new(status: :noop, channel: channel, previous_state: previous_state) if settled?

        if state == "open"
          reopen!
        else
          close!
        end
        Result.new(status: :updated, channel: channel, previous_state: previous_state)
      end
    end

    private

    attr_reader :channel, :state

    # A repeat call must not inject a second timeline message. "Same state" is
    # not enough on its own: a channel can read "open" while sitting detached
    # (dismissed by the user, or reopened only in GitHub), and that still needs
    # the reactivation half of the transition applied.
    def settled?
      return false unless channel.pr_state == state

      if state == "open"
        channel.active? && !channel.dismissed?
      else
        channel.detached?
      end
    end

    # Mirrors WebhooksController's reopen handling: state back to active and
    # the chip un-dismissed, so the channel resurfaces under `not_dismissed`
    # and resumes receiving events.
    def reopen!
      channel.state = :active
      channel.dismissed_at = nil
      channel.pr_state = "open"
      channel.save!
      channel.inject_into_topic!(channel.reopened_message)
    end

    # Mirrors the closed-event path: set the badge, post the closing message,
    # then detach — in that order, so the chip stays visible (now merged /
    # closed) until the user dismisses it.
    def close!
      channel.pr_state = state
      channel.save!
      channel.inject_into_topic!(channel.closed_message(state))
      channel.detach! if channel.active?
    end
  end
end

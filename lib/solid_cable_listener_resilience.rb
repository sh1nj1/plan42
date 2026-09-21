# frozen_string_literal: true

# Keeps the Solid Cable listener thread alive across *any* runtime error.
#
# solid_cable polls `solid_cable_messages` from one dedicated thread per
# process, and that thread is the only thing that pushes a broadcast out to
# connected WebSocket clients. The gem wraps it like this:
#
#   @thread = Thread.new do
#     begin
#       listen
#     rescue *CONNECTION_ERRORS
#       retry if retry_connecting?
#     end
#   end
#
# So the loop survives `reconnect_attempts` ActiveRecord connection errors
# (default: 1, with no delay) and nothing else. Once it gives up, the thread
# exits without a log line while the process keeps happily accepting
# subscriptions: every broadcast still INSERTs into `solid_cable_messages`,
# nobody ever reads it back out, and the whole app looks like it lost realtime
# until someone restarts the container. A single DB restart or pool timeout is
# enough to trigger it, and at a 0.1s polling interval the thread checks out a
# connection ten times a second.
#
# Prepended onto the listener, this retries the polling loop forever with a
# bounded backoff and logs every failure, so the outage is both self-healing
# and visible.
module SolidCableListenerResilience
  # Seconds to wait before the Nth consecutive retry; the last entry is the
  # ceiling for every failure after that.
  BACKOFF = [ 0.1, 0.5, 1, 2, 5, 10, 30 ].freeze

  # A quiet stretch this long means the loop recovered, so the next failure
  # starts the backoff over instead of resuming at the ceiling.
  RESET_AFTER = 60.0

  class << self
    # Installs only for environments that actually run the solid_cable
    # adapter. Development uses `async` and test uses `test`; neither has a
    # listener thread to guard.
    def install_if_configured!(listener_class = default_listener_class)
      return false unless cable_adapter == "solid_cable"

      install!(listener_class)
    end

    def cable_adapter
      Rails.application.config_for(:cable)[:adapter].to_s
    rescue StandardError
      nil
    end

    # Prepends this module onto solid_cable's listener. Returns true when it
    # installed, false when there was nothing to patch or it was already
    # installed, so a gem upgrade that moves the class can never break boot.
    def install!(listener_class = default_listener_class)
      return false unless listener_class.is_a?(Module)
      return false if listener_class.ancestors.include?(self)

      listener_class.prepend(self)
      true
    end

    def default_listener_class
      return nil unless defined?(::ActionCable::SubscriptionAdapter::SolidCable::Listener)

      ::ActionCable::SubscriptionAdapter::SolidCable::Listener
    end

    def report(error, failures:, delay:)
      Rails.logger&.error(
        "[solid_cable] listener loop crashed (consecutive failure ##{failures}), " \
        "retrying in #{delay}s: #{error.class}: #{error.message}"
      )
      Rails.logger&.error(error.backtrace.first(20).join("\n")) if error.backtrace

      Rails.error&.report(error, handled: true, source: "solid_cable") if Rails.respond_to?(:error)
    rescue StandardError
      # Never let reporting take down the retry loop itself.
      nil
    end
  end

  def listen
    failures = 0
    last_failure_at = nil

    begin
      super
    rescue StandardError => error
      # `Stop` (raised by `shutdown`) descends from Exception, not
      # StandardError, so an orderly shutdown still ends the thread here.
      now = monotonic_now
      failures = 0 if last_failure_at && (now - last_failure_at) > RESET_AFTER
      last_failure_at = now
      failures += 1

      delay = BACKOFF[[ failures, BACKOFF.size ].min - 1]
      SolidCableListenerResilience.report(error, failures: failures, delay: delay)
      reclaim_critical_permit

      sleep delay
      retry
    end
  end

  private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # `listen`'s own `ensure` releases the critical-section permit on its way
    # out, which is right when the thread is about to die and wrong when it is
    # about to restart. Take the permit back so `shutdown` keeps waiting for a
    # safe interruption point instead of raising into the middle of a poll.
    def reclaim_critical_permit
      return unless defined?(@critical) && @critical.respond_to?(:try_acquire)

      @critical.try_acquire
    rescue StandardError
      nil
    end
end

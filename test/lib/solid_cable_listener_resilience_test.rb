# frozen_string_literal: true

require "test_helper"
require "yaml"

class SolidCableListenerResilienceTest < ActiveSupport::TestCase
  # solid_cable runs the polling loop that feeds every WebSocket client from a
  # single thread and only rescues connection errors, `reconnect_attempts`
  # times. When it gives up the thread exits without a log line, broadcasts
  # keep landing in `solid_cable_messages`, and nothing reads them back out —
  # realtime is dead process-wide until a restart. These cases pin the
  # retry-forever-and-say-so behaviour that replaces it.

  # Stands in for `ActionCable::SubscriptionAdapter::SolidCable::Listener`:
  # `listen` raises the scripted errors in order, then returns like the real
  # one does after `shutdown`.
  class FakeListener
    attr_reader :listen_calls, :slept

    def initialize(errors: [], critical: nil)
      @errors = errors.dup
      @critical = critical unless critical.nil?
      @listen_calls = 0
      @slept = []
    end

    def listen
      @listen_calls += 1
      error = @errors.shift
      raise error if error

      :stopped
    end

    # Shadows Kernel#sleep so the backoff is observable and instant.
    def sleep(seconds)
      @slept << seconds
    end
  end

  class PermitSpy
    attr_reader :try_acquire_calls

    def initialize(&on_acquire)
      @try_acquire_calls = 0
      @on_acquire = on_acquire
    end

    def try_acquire
      @try_acquire_calls += 1
      @on_acquire&.call
      true
    end
  end

  class NullReporter
    attr_reader :reported

    def initialize
      @reported = []
    end

    def report(error, **options)
      @reported << [ error, options ]
    end
  end

  setup do
    @original_logger = Rails.logger
    @log = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown do
    Rails.logger = @original_logger
  end

  test "restarts the polling loop after a crash instead of letting the thread die" do
    listener = build_listener(errors: [ RuntimeError.new("boom") ])

    assert_equal :stopped, listener.listen
    assert_equal 2, listener.listen_calls
    assert_equal [ 0.1 ], listener.slept
  end

  test "recovers from the connection errors that solid_cable gives up on" do
    errors = [
      ActiveRecord::ConnectionNotEstablished.new("gone"),
      ActiveRecord::ConnectionTimeoutError.new("pool exhausted"),
      ActiveRecord::ConnectionFailed.new("reset")
    ]
    listener = build_listener(errors: errors)

    assert_equal :stopped, listener.listen
    assert_equal 4, listener.listen_calls
  end

  test "escalates the backoff and holds it at the ceiling" do
    listener = build_listener(errors: Array.new(9) { RuntimeError.new("boom") })

    listener.listen

    assert_equal [ 0.1, 0.5, 1, 2, 5, 10, 30, 30, 30 ], listener.slept
  end

  test "restarts the backoff once the loop has been healthy again" do
    # Failures 1 and 2 are back to back; failure 3 lands after a quiet stretch.
    clock = [ 0.0, 0.5, 0.5 + SolidCableListenerResilience::RESET_AFTER + 1 ]
    listener = build_listener(errors: Array.new(3) { RuntimeError.new("boom") }, clock: clock)

    listener.listen

    assert_equal [ 0.1, 0.5, 0.1 ], listener.slept
  end

  test "logs the failure and the backtrace so the outage is not silent" do
    error = RuntimeError.new("boom")
    error.set_backtrace([ "app/models/thing.rb:1:in `poll'" ])

    build_listener(errors: [ error ]).listen

    assert_match(/\[solid_cable\] listener loop crashed \(consecutive failure #1\)/, @log.string)
    assert_match(/retrying in 0\.1s: RuntimeError: boom/, @log.string)
    assert_match(/app\/models\/thing\.rb:1/, @log.string)
  end

  test "reports the failure to the error reporter" do
    reporter = NullReporter.new
    error = RuntimeError.new("boom")

    Rails.stub(:error, reporter) do
      build_listener(errors: [ error ]).listen
    end

    assert_equal 1, reporter.reported.size
    reported_error, options = reporter.reported.first
    assert_same error, reported_error
    assert_equal true, options[:handled]
    assert_equal "solid_cable", options[:source]
  end

  test "keeps retrying when there is no error reporter" do
    listener = build_listener(errors: [ RuntimeError.new("boom") ])

    Rails.stub(:error, nil) do
      assert_equal :stopped, listener.listen
    end

    assert_equal 2, listener.listen_calls
  end

  test "keeps retrying when reporting itself blows up" do
    reporter = Object.new
    def reporter.report(*) = raise("reporter down")
    listener = build_listener(errors: [ RuntimeError.new("boom") ])

    Rails.stub(:error, reporter) do
      assert_equal :stopped, listener.listen
    end

    assert_equal 2, listener.listen_calls
  end

  test "lets an orderly shutdown end the thread" do
    stop = Class.new(Exception)
    listener = build_listener(errors: [ stop.new("stop") ])

    assert_raises(stop) { listener.listen }
    assert_equal 1, listener.listen_calls
    assert_empty listener.slept
  end

  test "takes back the critical-section permit before restarting the loop" do
    permit = PermitSpy.new
    listener = build_listener(errors: [ RuntimeError.new("boom") ], critical: permit)

    listener.listen

    assert_equal 1, permit.try_acquire_calls
  end

  test "restarts the loop even when the permit cannot be reclaimed" do
    permit = PermitSpy.new { raise "semaphore down" }
    listener = build_listener(errors: [ RuntimeError.new("boom") ], critical: permit)

    assert_equal :stopped, listener.listen
    assert_equal 1, permit.try_acquire_calls
  end

  test "restarts the loop when the listener has no semaphore to reclaim" do
    listener = build_listener(errors: [ RuntimeError.new("boom") ], critical: Object.new)

    assert_equal :stopped, listener.listen
    assert_equal 2, listener.listen_calls
  end

  test "installs onto a listener class exactly once" do
    listener_class = Class.new(FakeListener)

    assert SolidCableListenerResilience.install!(listener_class)
    assert_not SolidCableListenerResilience.install!(listener_class)
    assert_includes listener_class.ancestors, SolidCableListenerResilience
  end

  test "does nothing when the listener class is missing" do
    assert_not SolidCableListenerResilience.install!(nil)
  end

  test "points at the solid_cable listener class by default" do
    assert_equal ActionCable::SubscriptionAdapter::SolidCable::Listener,
                 SolidCableListenerResilience.default_listener_class
  end

  # Canaries: a solid_cable upgrade that renames either of these turns the
  # patch into a no-op, which would only show up in production as realtime
  # silently dying again.
  test "solid_cable still runs the loop in the method this wraps" do
    assert SolidCableListenerResilience.default_listener_class.method_defined?(:listen)
  end

  test "solid_cable's shutdown signal still bypasses the retry" do
    stop = SolidCableListenerResilience.default_listener_class::Stop

    assert_operator stop, :<, Exception
    assert_not stop <= StandardError, "Stop must not be rescued as a retryable error"
  end

  test "installs only for the solid_cable adapter" do
    listener_class = Class.new(FakeListener)

    SolidCableListenerResilience.stub(:cable_adapter, "test") do
      assert_not SolidCableListenerResilience.install_if_configured!(listener_class)
    end
    assert_not_includes listener_class.ancestors, SolidCableListenerResilience

    SolidCableListenerResilience.stub(:cable_adapter, "solid_cable") do
      assert SolidCableListenerResilience.install_if_configured!(listener_class)
    end
    assert_includes listener_class.ancestors, SolidCableListenerResilience
  end

  test "reads the adapter from the cable config" do
    assert_equal "test", SolidCableListenerResilience.cable_adapter
  end

  test "treats an unreadable cable config as no adapter" do
    Rails.application.stub(:config_for, ->(*) { raise "no such file" }) do
      assert_nil SolidCableListenerResilience.cable_adapter
    end
  end

  test "production retries connection errors with a backoff instead of giving up" do
    cable = YAML.load_file(Rails.root.join("config/cable.yml"), aliases: true)

    # An Integer here would mean "N retries with no delay"; the gem only treats
    # an Array as a backoff schedule. The counter resets after any successful
    # poll, so this is effectively unlimited retries with a 30s ceiling.
    attempts = cable.dig("production", "reconnect_attempts")
    assert_kind_of Array, attempts
    assert_equal [ 0.1, 0.5, 1, 2, 5, 10, 30 ], attempts
    assert_equal cable["production"], cable["desktop"]
  end

  private

    def build_listener(errors:, critical: nil, clock: nil)
      klass = Class.new(FakeListener)
      SolidCableListenerResilience.install!(klass)
      listener = klass.new(errors: errors, critical: critical)
      # A singleton method wins over the prepended module, so this is the one
      # seam that can pin the clock without stubbing Process globally.
      listener.define_singleton_method(:monotonic_now) { clock.shift } if clock
      listener
    end
end

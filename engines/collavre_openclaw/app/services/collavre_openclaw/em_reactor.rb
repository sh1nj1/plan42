require "eventmachine"

module CollavreOpenclaw
  # Manages a single EventMachine reactor thread shared by all WebSocket connections.
  # Thread-safe: multiple Rails threads can schedule work via .next_tick.
  class EmReactor
    class << self
      def ensure_running!
        @mutex ||= Mutex.new
        @mutex.synchronize do
          return if EM.reactor_running?

          @thread = Thread.new do
            Thread.current.name = "openclaw-em-reactor"
            EM.run
          end

          # Wait until the reactor is actually running
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          until EM.reactor_running?
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise "EventMachine reactor failed to start within 5 seconds"
            end
            sleep 0.01
          end
        end
      end

      def stop!
        @mutex&.synchronize do
          return unless EM.reactor_running?

          # Must stop EM from within the reactor thread
          EM.next_tick { EM.stop }
          @thread&.join(5)
          @thread = nil
        end
      end

      def running?
        EM.reactor_running?
      end

      # Schedule a block to run in the EM reactor thread.
      # Safe to call from any thread.
      def next_tick(&block)
        ensure_running!
        EM.next_tick(&block)
      end
    end
  end
end

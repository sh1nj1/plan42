require "test_helper"

module Collavre
  class AiAgentJobQueueTest < ActiveSupport::TestCase
    # An agent turn runs for minutes; on the 3-thread default worker three
    # turns starve every broadcast, mailer and notification behind them and
    # silently cap concurrency at 3. The dedicated queue's AI_AGENT_THREADS
    # sets execution capacity; orchestrator's max_concurrent_jobs (default 5)
    # gates admission—raise both together if increasing concurrency.
    test "runs on the dedicated ai_agents queue" do
      assert_equal "ai_agents", AiAgentJob.new.queue_name
    end
  end
end

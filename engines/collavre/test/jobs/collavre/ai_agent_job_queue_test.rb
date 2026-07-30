require "test_helper"

module Collavre
  class AiAgentJobQueueTest < ActiveSupport::TestCase
    # An agent turn runs for minutes; on the 3-thread default worker three
    # turns starve every broadcast, mailer and notification behind them and
    # silently cap real AI concurrency at 3 regardless of
    # OrchestratorPolicy#max_concurrent_jobs. The dedicated queue's worker
    # (config/queue.yml, AI_AGENT_THREADS) is the real execution capacity.
    test "runs on the dedicated ai_agents queue" do
      assert_equal "ai_agents", AiAgentJob.new.queue_name
    end
  end
end

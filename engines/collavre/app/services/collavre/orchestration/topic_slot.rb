# frozen_string_literal: true

module Collavre
  module Orchestration
    # The single rule for who may hold a topic's concurrency slot, shared by the
    # two paths that hand one out: AiAgentJob's admission of a fresh dispatch and
    # AgentOrchestrator.dequeue_next_for_topic's promotion of a parked waiter.
    #
    # Keeping the rule in one place is the point. When only admission enforced
    # it, promotion could still hand a second slot to an agent that already held
    # one, or overfill a topic outright — and TaskCoalescer folds only `queued`
    # rows, so two concurrent turns for one agent can never be merged afterwards.
    module TopicSlot
      # Serialize every admission and promotion for one topic scope on one
      # stable row. SELECT ... FOR UPDATE on Postgres; the SQLite visitor drops
      # the lock clause, where writes are serialized anyway.
      #
      # A creative's Main topic carries topic_id == nil, which is a real scope
      # (occupancy is counted as topic_id: nil within the creative) but has no
      # topic row to lock — fall back to the creative, which is just as stable
      # and is shared by exactly the dispatches that compete for that slot.
      # Tasks carry topic_id with no foreign key, so a deleted topic leaves rows
      # pointing at a row that is gone — and a delayed job can carry that id long
      # after the fact. Returning the missing topic's nil without trying the
      # creative would run admission, promotion and notice dedup with no
      # serialization at all: silently the one state this lock exists to prevent.
      def self.lock!(topic_id, creative_id = nil)
        if topic_id
          topic = Topic.lock.find_by(id: topic_id)
          return topic if topic
        end
        return Creative.lock.find_by(id: creative_id) if creative_id

        nil
      end

      # May `agent_id` take a slot in this topic scope right now?
      #
      # Deliberately NOT gated on coalesce_pending_tasks?: that switch governs
      # whether waiters are folded together, not whether topic_max_concurrent_jobs
      # is enforced. Skipping the check when it is off would let a burst start
      # one concurrent turn per comment in a topic limited to one.
      #
      # Occupancy counts running/delegated (executing) plus pending (claimed,
      # job not started) and pending_approval (paused, keeps its resource and
      # does not drain the queue) — treating any of those as free is exactly how
      # a second turn slips in.
      def self.available_for?(agent_id, topic_id, creative_id, context)
        topic_max = PolicyResolver.new(context || {}).topic_max_concurrent_jobs
        return true unless topic_max

        occupying = Task.occupying_topic_slot(topic_id, creative_id)
        return false if occupying.count >= topic_max

        # A free slot is not automatically THIS agent's to take. topic_max > 1
        # exists to run *different* agents in parallel, so an agent that already
        # has a turn in flight here must wait rather than answer itself twice.
        !occupying.where(agent_id: agent_id).exists?
      end
    end
  end
end

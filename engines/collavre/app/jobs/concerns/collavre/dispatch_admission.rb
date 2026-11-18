# frozen_string_literal: true

module Collavre
  # Admission is completed before AiAgentJob reserves resources or calls an agent.
  module DispatchAdmission
    private

    def admit_keep_resumption(task)
      result = Orchestration::KeepDispatchAdmission.call(task.trigger_event_payload, task.agent) { yield }
      if result == :rejected
        Workflow::TaskAdmission.reject_resumption!(task)
        return false
      end
      result
    end

    def admit_new_dispatch(agent, event_name, context, replay_identity)
      CliProxy::InlineReplayAdmission.call(context, replay_identity) do |current_context|
        agent.reload if replay_identity
        Orchestration::KeepDispatchAdmission.call(current_context, agent) do
          create_dispatch_task(agent, event_name, current_context)
        end
      end
    end

    def prepare_dispatch_context(agent, event_name, context)
      # Create new task
      return :rejected unless Workflow::TaskAdmission.permitted?(context, agent)

      # Guard: skip if the Claude Channel session has unregistered (or its WS
      # dropped) during the window between Scheduler enqueue and this job
      # firing. AgentsController#destroy / AgentChannel#unsubscribed remove
      # the last presence row, so no live presence here means there is no MCP
      # client to receive the dispatch. Without
      # this guard, a :delayed (busy / rate-limited) enqueue from
      # Scheduler#evaluate would materialize a fresh Task, flip it to
      # "delegated", and broadcast to a clientless agent:user:<id> stream
      # — holding the topic/agent slot until stuck recovery.
      if agent.claude_channel_agent? && !agent.claude_channel_online?
        Rails.logger.info(
          "[AiAgentJob] Skipping Claude Channel job for agent #{agent.id}: " \
          "session offline (no live presence, event=#{event_name})"
        )
        return :rejected
      end

      # Guard: an exclusive primary-agent assignment created (or moved) after
      # this dispatch was scheduled must still bind it. A :delayed decision
      # (agent busy / rate limited) sits in the job queue with its agent already
      # chosen and is never re-matched, so without this a demoted agent speaks
      # in a topic that now belongs to someone else. Unlike a queued waiter
      # there is no Task yet to cancel, so cancelling on assignment change
      # cannot cover this path — the check has to happen here.
      prepared_context = context && Orchestration::Matcher.prepare_waiting_payload(context, agent)
      if context && !prepared_context
        Rails.logger.info(
          "[AiAgentJob] Skipping job for agent #{agent.id}: topic " \
          "#{context.dig('topic', 'id')} no longer permits the recorded agent " \
          "(event=#{event_name})"
        )
        return :rejected
      end

      prepared_context
    end

    def create_dispatch_task(agent, event_name, context)
      context = prepare_dispatch_context(agent, event_name, context)
      return :rejected if context == :rejected

      # Guard: skip if there's already a running task for the same agent + comment
      comment_id = context&.dig("comment", "id")
      if Workflow::TaskAdmission.duplicate_dispatch?(context, agent)
        Rails.logger.warn(
          "[AiAgentJob] Skipping duplicate: agent #{agent.id} already has a running task " \
          "for comment #{comment_id} (event=#{event_name})"
        )
        return :rejected
      end

      # Guard: the same question the orchestrator asks before enqueueing, asked
      # again where the answer is authoritative. This job can sit in the queue
      # while the covering turn assembles its payload, so a dispatch that was
      # not droppable at enqueue time can be droppable by the time it runs —
      # and the enqueue door alone would leave that window open.
      #
      # As at the enqueue door, the drop only happens if the covering turn
      # records it — otherwise this dispatch has nobody to restore it.
      covering = Orchestration::DeliveryRecord.covering_task(agent, comment_id, context, event_name)
      if covering && Orchestration::DeliveryRecord.claim_drop!(covering, comment_id, context: context)
        Rails.logger.info(
          "[AiAgentJob] Skipping dispatch: comment #{comment_id} was already delivered to " \
          "agent #{agent.id} by in-flight task #{covering.id} (event=#{event_name})"
        )
        return :rejected
      end

      # Guard: the Scheduler's topic-concurrency check counts Task rows, but
      # the row for an :immediate decision is only created *here*. A burst of
      # comments dispatched before the first job runs therefore all see an
      # empty topic and are all judged :immediate — several turns run at once
      # in a topic limited to one. Re-check at the moment the row is created,
      # where the answer is authoritative, and defer into the queue instead.
      admit_or_defer!(agent, event_name, context)
    end
  end
end

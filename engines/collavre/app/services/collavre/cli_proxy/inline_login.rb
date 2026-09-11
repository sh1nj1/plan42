# frozen_string_literal: true

module Collavre
  module CliProxy
    # Persists only the identity of the failed turn and a proxy session id.
    # Login URLs, one-time codes and credentials never enter comments or tasks.
    class InlineLogin
      attr_reader :comment, :task, :workspace, :agent

      def self.record!(task, comment, error, content:, retryable:)
        task.with_lock do
          # Stop and stuck recovery share this lock; preserve whichever transition won.
          raise CancelledError unless task.running?

          retryable &&= !task.trigger_event_payload[Orchestration::DeliveryRecord::HANDED_OFF_KEY]
          Orchestration::DeliveryRecord.mark_handoff_failed!(task) if retryable
          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" => {
            "engine" => error.engine, "workspace_id" => error.workspace.id, "retryable" => retryable
          }))
          next unless comment

          text = I18n.t("collavre.inline_agent_login.required", engine: error.engine)
          # The commit callback broadcasts the card once. An immediate broadcast
          # would let users start a form that the queued replacement then discards.
          comment.update!(content: [ content.presence, text ].compact.join("\n\n"))
        end
      end

      def initialize(comment, user)
        @comment, @user = comment, user
        @task = comment.task
        @agent = task&.agent
        @workspace = AgentWorkspace.find_by(id: data["workspace_id"])
      end

      def data
        task&.trigger_event_payload&.fetch("engine_login", {}) || {}
      end

      def engine = data["engine"]

      def accessible?
        workspace && agent&.cli_proxy_agent? && agent.agent_gateway.active? &&
          workspace.agent_id == agent.id && workspace.agent_gateway_id == agent.agent_gateway_id &&
          comment.user_id == agent.id && comment.creative.has_permission?(@user, :feedback) &&
          agent.gateway_accessible_to?(@user) && original_comment.present?
      end

      # Settled cards expose only a generic notice to viewers of the reply.
      def settled_card_visible?
        (data["replay_abandoned"] || data["replay_completed"]) && comment.creative.has_permission?(@user, :read)
      end

      def manageable?
        return false unless accessible?

        if workspace.agent_gateway.shared?
          @user.id == agent.created_by_id || @user.system_admin?
        else
          workspace.user_id == @user.id
        end
      end

      def client
        @client ||= Client.new(gateway: workspace.agent_gateway, workspace: workspace)
      end

      def session_snapshot
        return if data["resumed"]
        return unless data["session_id"] && data["session_user_id"] == @user.id && !data["authorized"]

        id = data["session_id"]
        observe_session!(client.auth_session(engine, id), id)
      rescue Client::Error => error
        { "engine" => engine, "status" => "failed", "error" => { "message" => error.message } }
      end

      def check_session_mutable!
        fail_with!("already_resumed") if data["resumed"]
      end

      def begin_session!
        attempt = SecureRandom.uuid
        # Claim before proxy I/O. Invalidate the previous session so its in-flight
        # polls/submissions cannot authorize or resume this new attempt.
        update_data! { |value| value.merge("session_attempt" => attempt, "session_id" => nil,
                                         "session_user_id" => @user.id, "authorized" => false) }
        attempt
      end

      def remember_session!(response, attempt:)
        update_data! do |value|
          fail_with!("session_superseded") unless value["session_attempt"] == attempt
          value.merge("session_id" => response.fetch("sessionId"), "session_user_id" => @user.id,
                      "authorized" => response["status"] == "authorized")
        end
      end

      def check_session!(id)
        return if data["session_id"] == id && data["session_user_id"] == @user.id

        fail_with!("session_superseded")
      end

      def observe_session!(response, id)
        update_data! do |value|
          fail_with!("session_superseded") unless value["session_id"] == id && value["session_user_id"] == @user.id
          value.merge("authorized" => response["status"] == "authorized",
                      "session_id" => response["status"] == "cancelled" ? nil : id)
        end
        response
      end

      def resume!
        task.with_lock do
          return if data["resumed"]
          fail_with!("not_authorized") unless data["authorized"] && data["session_user_id"] == @user.id
          source = original_comment
          fail_with!("cannot_retry") unless data["retryable"] && task.done? && source

          payload = retry_payload(source)
          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" => data.merge("resumed" => true)))
          enqueue_retry(payload)
        end
      end

      # Queue entries carry only ids. Rebuild at execution as well as scheduling:
      # there is no replay Task for comment cancellation to find during a delay.
      def replay_payload
        # Wait for resume!'s claim transaction before inspecting resumed.
        task&.with_lock do
          fail_with!("cannot_retry") unless manageable? && task.done? && data["retryable"] && data["resumed"]
          fail_with!("not_authorized") unless data["authorized"] && data["session_user_id"] == @user.id

          source = original_comment
          fail_with!("cannot_retry") unless source
          payload = retry_payload(source)
          validate_retry_assignment!(payload)
          payload
        end
      end

      # Cleanup must survive deletion of the reply card or initiating user.
      def self.abandon_replay!(task, pending: false)
        task.with_lock do
          data = task.trigger_event_payload&.fetch("engine_login", {}) || {}
          return if data["replay_completed"]
          return unless data["resumed"] || (pending && data["retryable"])

          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" =>
            data.merge("retryable" => false, "resumed" => false, "replay_abandoned" => true)))
        end
        # The task is already terminal, so saving its payload cannot run these
        # status-change callbacks. Release loop completion and refresh the card once.
        task.fire_completion_callbacks_after_external_claim
        comment = task.reply_comment
        return if !comment || comment.private?

        comment.broadcast_replace_later_to([ comment.creative, :comments ], partial: "collavre/comments/comment")
      end

      private

      def original_comment
        return unless task && comment.creative_id == task.creative_id && comment.topic_id == task.topic_id

        id = task.trigger_event_payload&.dig("comment", "id")
        source = Comment.visible_to(@user).find_by(id: id, creative_id: task.creative_id, topic_id: task.topic_id)
        source unless source&.private? || source&.approval_action?
      end

      def enqueue_retry(payload)
        validate_retry_assignment!(payload)
        decision = Orchestration::Scheduler.new(payload).schedule([ agent ]).first
        fail_with!("cannot_retry") if decision.nil? || decision[:timing] == :rejected

        job = decision[:timing] == :delayed ? InlineAgentReplayJob.set(wait: decision[:delay]) : InlineAgentReplayJob
        result = job.perform_later(comment.id, @user.id, task.id)
        fail_with!("cannot_retry") unless result && result.successfully_enqueued?
      end

      def validate_retry_assignment!(payload)
        fail_with!("cannot_retry") unless Orchestration::Matcher.permits_creative_access?(payload, agent) &&
          Orchestration::Matcher.permits_assignment?(payload, agent)
      end

      def retry_payload(source)
        # Rebuild content and mentions after login, before assignment checks.
        payload = Orchestration::TaskCoalescer.reanchor_payload(task.trigger_event_payload, source)
            .except("engine_login", *Orchestration::DeliveryRecord::TURN_SCOPED_KEYS)
        # Preserve explicit principals, including nil. Shared workspaces have no
        # user: leave the key absent so normal source-principal resolution applies.
        payload["workspace_user_id"] = workspace.user_id unless payload.key?("workspace_user_id") || workspace.user_id.nil?
        payload
      end

      def update_data!
        task.with_lock do
          # A proxy response can arrive after resume! commits its replay claim.
          check_session_mutable!
          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" => yield(data)))
        end
      end

      def fail_with!(code)
        raise Client::Error.new(I18n.t("collavre.inline_agent_login.errors.#{code}"), status: 409, code: code)
      end
    end
  end
end

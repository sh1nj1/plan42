# frozen_string_literal: true

module Collavre
  module CliProxy
    # Persists only the identity of the failed turn and a proxy session id.
    # Login URLs, one-time codes and credentials never enter comments or tasks.
    class InlineLogin
      attr_reader :comment, :task, :workspace, :agent

      def self.record!(task, comment, error, content:, retryable:)
        retryable &&= !task.reload.trigger_event_payload[Orchestration::DeliveryRecord::HANDED_OFF_KEY]
        Orchestration::DeliveryRecord.mark_handoff_failed!(task) if retryable
        task.with_lock do
          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" => {
            "engine" => error.engine, "workspace_id" => error.workspace.id, "retryable" => retryable
          }))
        end
        return unless comment

        text = I18n.t("collavre.inline_agent_login.required", engine: error.engine)
        # The commit callback broadcasts the card once. An immediate broadcast
        # would let users start a form that the queued replacement then discards.
        comment.update!(content: [ content.presence, text ].compact.join("\n\n"))
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
        return unless data["session_id"] && data["session_user_id"] == @user.id && !data["authorized"]

        id = data["session_id"]
        observe_session!(client.auth_session(engine, id), id)
      rescue Client::Error => error
        { "engine" => engine, "status" => "failed", "error" => { "message" => error.message } }
      end

      def remember_session!(response)
        update_data! { |value| value.merge("session_id" => response.fetch("sessionId"), "session_user_id" => @user.id,
                                         "authorized" => response["status"] == "authorized") }
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

      private

      def original_comment
        id = task&.trigger_event_payload&.dig("comment", "id")
        source = comment.creative.comments.visible_to(@user).find_by(id: id, topic_id: comment.topic_id)
        source unless source&.private? || source&.approval_action?
      end

      def enqueue_retry(payload)
        fail_with!("cannot_retry") unless Orchestration::Matcher.permits_creative_access?(payload, agent) &&
          Orchestration::Matcher.permits_assignment?(payload, agent)
        decision = Orchestration::Scheduler.new(payload).schedule([ agent ]).first
        fail_with!("cannot_retry") if decision.nil? || decision[:timing] == :rejected

        job = decision[:timing] == :delayed ? AiAgentJob.set(wait: decision[:delay]) : AiAgentJob
        result = job.perform_later(agent.id, task.trigger_event_name, payload)
        fail_with!("cannot_retry") unless result && result.successfully_enqueued?
      end

      def retry_payload(source)
        # Rebuild content and mentions after login, before assignment checks.
        Orchestration::TaskCoalescer.reanchor_payload(task.trigger_event_payload, source)
            .except("engine_login", *Orchestration::DeliveryRecord::TURN_SCOPED_KEYS)
            .merge("workspace_user_id" => workspace.user_id || task.trigger_event_payload["workspace_user_id"])
      end

      def update_data!
        task.with_lock do
          task.update!(trigger_event_payload: task.trigger_event_payload.merge("engine_login" => yield(data)))
        end
      end

      def fail_with!(code)
        raise Client::Error.new(I18n.t("collavre.inline_agent_login.errors.#{code}"), status: 409, code: code)
      end
    end
  end
end

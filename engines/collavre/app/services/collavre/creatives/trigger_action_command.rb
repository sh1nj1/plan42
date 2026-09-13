# frozen_string_literal: true

module Collavre
  module Creatives
    # Executes one trigger UI command after authorizing its target creative.
    class TriggerActionCommand
      ACTIONS = %w[toggle_container start pause resume restart].freeze
      PAUSABLE_STATES = %w[running pending_verification].freeze
      RESUMABLE_STATES = %w[paused idle stuck awaiting_user].freeze
      RESTARTABLE_STATES = %w[completed max_reached stuck].freeze

      Result = Struct.new(:error, :status, keyword_init: true) do
        def success?
          error.nil?
        end
      end

      def initialize(creative:, user:, action:, enabled: nil)
        @creative = creative
        @user = user
        @action = action
        @enabled = enabled
      end

      def call
        return failure(:unprocessable_entity, "collavre.drop_trigger.unknown_action") unless ACTIONS.include?(action)
        return failure(:forbidden, "collavre.creatives.errors.no_permission") unless target.has_permission?(user, :write)

        @transitioned_loop_data = nil
        outcome = send(action)
        outcome.is_a?(Result) ? outcome : Result.new
      end

      private

      attr_reader :creative, :user, :action, :enabled

      def target
        @target ||= action == "toggle_container" ? creative.effective_origin(Set.new) : creative
      end

      def toggle_container
        previous_enabled = nil
        target.with_lock do
          previous_enabled = target.drop_trigger_enabled?
          data = (target.data || {}).deep_dup
          data["trigger"] ||= {}
          data["trigger"]["on_child_enter"] = ActiveModel::Type::Boolean.new.cast(enabled)
          target.update!(data: data)
        end
        notify_missing_agent if !previous_enabled && target.drop_trigger_enabled?
      end

      def start
        parent = creative.parent
        return failure(:unprocessable_entity, "collavre.drop_trigger.not_a_container") unless parent&.drop_trigger_enabled?

        DropTriggerJob.perform_later(parent.id, creative.id)
      end

      def pause
        transition_loop(PAUSABLE_STATES) { |loop_data| loop_data["state"] = "paused" }
      end

      def resume
        transition_loop(RESUMABLE_STATES) { |loop_data| loop_data["state"] = "running" }
        post_continue_to_agent if @transitioned_loop_data
      end

      def restart
        transition_loop(RESTARTABLE_STATES) do |loop_data|
          loop_data.merge!("state" => "running", "current_iteration" => 0, "infra_retry_count" => 0)
        end
        post_restart_trigger if @transitioned_loop_data
      end

      def transition_loop(allowed_states)
        creative.with_lock do
          data = (creative.data || {}).deep_dup
          loop_data = data.dig("trigger", "loop")
          return unless loop_data && allowed_states.include?(loop_data["state"])

          yield loop_data
          creative.update!(data: data)
          @transitioned_loop_data = loop_data
        end
      end

      def post_continue_to_agent
        parent, topic, agent = trigger_context
        return log_missing_context("resume", topic) unless parent && topic && agent

        content = "@#{agent.name}: #{I18n.t(
          'collavre.trigger_loop.continue',
          iteration: @transitioned_loop_data["current_iteration"] || 0,
          max: @transitioned_loop_data["max_iterations"] || 10
        )}"
        comment = create_trigger_comment(topic, content, skip_dispatch: false)
        Rails.logger.info("[TriggerAction] resume: posted continue comment #{comment.id} for creative #{creative.id}")
      end

      def post_restart_trigger
        parent, topic, agent = trigger_context
        return log_missing_context("restart", topic) unless parent && topic && agent

        content = "@#{agent.name}: #{restart_message(parent)}"
        comment = create_trigger_comment(topic, content, skip_dispatch: true)
        scheduled = SystemEvents::Dispatcher.dispatch("comment_created", comment.dispatch_payload, source: "trigger_restart")
        Rails.logger.info("[TriggerAction] restart: posted trigger comment #{comment.id}, dispatched to #{scheduled&.size || 0} agents")
      end

      def restart_message(parent)
        trigger_text = I18n.t(
          "collavre.drop_trigger.child_entered",
          child_description: creative.creative_snippet,
          child_id: creative.id,
          parent_description: parent.creative_snippet
        )
        "#{trigger_text}\n\n#{I18n.t('collavre.trigger_loop.instructions')}"
      end

      def trigger_context
        parent = creative.parent
        [ parent, creative.topics.find_by(name: "Drop Trigger"), parent&.find_ai_agent(:write) ]
      end

      def create_trigger_comment(topic, content, skip_dispatch:)
        creative.comments.create!(
          content: content,
          topic_id: topic.id,
          private: false,
          user: user,
          skip_dispatch: skip_dispatch
        )
      end

      def log_missing_context(operation, topic)
        Rails.logger.warn("[TriggerAction] #{operation}: missing topic=#{topic&.id} or agent for creative #{creative.id}")
      end

      def notify_missing_agent
        DropTriggerMissingAgentNotifier.new(creative: target).call
      end

      def failure(status, key)
        Result.new(error: I18n.t(key), status: status)
      end
    end
  end
end

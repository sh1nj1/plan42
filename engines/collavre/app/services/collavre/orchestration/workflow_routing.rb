# frozen_string_literal: true

module Collavre
  module Orchestration
    # The optional workflow tier between topic assignment and agent defaults.
    # An empty decision is exclusive; only a missing rule falls back.
    module WorkflowRouting
      private

      def match_with_workflow
        case PolicyResolver.new(@context).workflow_routing_mode
        when "off"
          match_by_expression
        when "on"
          match_by_workflow || match_by_expression
        else
          decision = safe_match_by_workflow
          fallback = match_by_expression
          log_workflow_shadow(decision, fallback)
          fallback
        end
      end

      def match_by_workflow
        conditions = Workflow::Conditions.new({}, @context)
        rule = workflow_rules.find do |candidate|
          candidate.event_name == @context["event_name"] &&
            conditions.match?(candidate.conditions, rule_id: candidate.creative_id)
        end
        return nil unless rule
        return [] unless rule.responder?

        agents = User.where(id: rule.agent_ids).order(:id).select do |agent|
          agent.ai_user? && has_creative_permission?(agent) && eligible_in_inbox?(agent)
        end
        if agents.empty?
          Rails.logger.warn("[Matcher] workflow_no_eligible_responder rule_id=#{rule.creative_id}")
        end
        agents
      end

      def workflow_rules
        @workflow_rules ||= begin
          @workflow_resolver ||= Workflow::Resolver.new(@context)
          @workflow_resolver.rules
        end
      end

      def safe_match_by_workflow
        @workflow_shadow_error = nil
        match_by_workflow
      rescue StandardError => exception
        # Do not include exception messages: they can contain rule or chat text.
        @workflow_shadow_error = exception.class.name
        :error
      end

      def log_workflow_shadow(decision, fallback)
        fields = workflow_shadow_fields(decision, fallback)
        line = fields.map { |key, value| "#{key}=#{JSON.generate(value)}" }.join(" ")
        Rails.logger.info("[Matcher] workflow_shadow #{line}")
      rescue StandardError
        # Diagnostics must never interrupt the existing routing decision.
        nil
      end

      def workflow_shadow_fields(decision, fallback)
        workflow_ids = decision == :error ? :error : Array(decision).map(&:id).sort
        expression_ids = fallback.map(&:id).sort
        {
          creative_id: @context.dig("creative", "id"),
          event: @context["event_name"],
          workflow: workflow_ids,
          expression: expression_ids,
          agree: workflow_ids == expression_ids,
          rules: @workflow_rules&.size || 0,
          correlation_id: SystemEvents::Envelope.in(@context)&.correlation_id,
          error: @workflow_shadow_error
        }
      end
    end
  end
end

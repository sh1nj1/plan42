# frozen_string_literal: true

module Collavre
  module Workflow
    # Re-read authoritative rows at every effect boundary; never re-anchor.
    class Safety
      STOP_REASONS = %w[scope_changed permission_revoked routing_disabled].freeze

      def initialize(execution)
        @execution = execution
        @chain = execution.chain
        @context = execution.context
      end

      def reason
        scope_reason || invocation_reason || mode_reason || rule_reason
      end

      def scope_reason
        creative = Creative.active.find_by(id: @chain.creative_id)
        topic_id = @context.dig("topic", "id").to_i
        topic = Topic.find_by(id: topic_id) unless topic_id.zero?
        return "scope_changed" unless creative && (topic_id.zero? || (topic && !topic.archived? && topic.creative_id == creative.id))
        comment_reason(Comment.find_by(id: @context.dig("comment", "id")))
      end

      def comment_reason(comment, topic_id: @context.dig("topic", "id").to_i)
        return "scope_changed" unless comment && comment.creative_id == @chain.creative_id && comment.topic_id.to_i == topic_id
        "permission_revoked" if comment.private? || comment.approval_action? || comment.waiting_notice?
      end

      def invocation_reason
        invocation = @context["invocation"]
        return unless invocation
        topic = Topic.find_by(id: invocation.dig("topic", "id"))
        return "scope_changed" unless Invocation.usable_topic?(topic, @chain.creative_id)
        comment_reason(Comment.find_by(id: invocation.dig("comment", "id")), topic_id: topic.id)
      end

      def owner
        comment = Comment.find_by(id: @context.dig("comment", "id"))
        owner = comment&.creative&.user
        owner if owner && !owner.ai_user? && permitted?(owner)
      end

      def permitted?(user)
        Creatives::PermissionChecker.current_allowed?(@chain.creative_id, user, :feedback)
      end

      private

      def mode_reason
        "routing_disabled" unless Orchestration::PolicyResolver.new(@context).workflow_routing_mode == "on"
      end

      def rule_reason
        "permission_revoked" unless Resolver.new(@context).reachable_rule?(@execution.rule_id)
      end
    end
  end
end

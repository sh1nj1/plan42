# frozen_string_literal: true

module Collavre
  module WorkflowEditable
    extend ActiveSupport::Concern

    included do
      helper_method :workflow_editor_creative?
    end

    def workflow_editor_creative?(creative)
      return false unless creative && creative.archived_at.nil?

      origin = creative.effective_origin(Set.new)
      origin.workflow? && origin.archived_at.nil?
    end

    def workflow
      return unless workflow_access?(@creative, :read)

      creative = @creative.effective_origin(Set.new)
      return unless active_workflow?(creative)

      render json: Workflow::Editor.new(creative, Current.user, placement: @creative).as_json
    end

    def create_workflow_rule
      return unless workflow_access?(@creative, :admin)

      creative = @creative.effective_origin(Set.new)
      return unless active_workflow?(creative)
      if !params[:description].is_a?(String) || params[:description].blank?
        return workflow_error(:title_required)
      end

      rule = creative.children.build(user: creative.user, description: params[:description],
                                     data: { "kind" => "workflow_rule" })
      save_workflow_rule(rule, creative, :created)
    end

    def update_workflow_rule
      return unless workflow_access?(@creative, :admin)
      return workflow_error(:not_direct_rule) unless editable_workflow_rule?

      creative = @creative.parent
      return unless workflow_access?(creative, :admin) && active_workflow?(creative)

      save_workflow_rule(@creative, creative, :ok)
    end

    private

    def creative_edit_access?
      if !params[:inline] && workflow_editor_creative?(@creative)
        return workflow_access?(@creative, :read)
      end
      return true if @creative.has_permission?(Current.user, :write)

      redirect_to @creative, alert: t("collavre.creatives.errors.no_permission")
      false
    end

    def workflow_access?(creative, permission)
      allowed = Creatives::PermissionFilter.new(user: Current.user)
        .readable_ids([ creative.id ], min_permission: permission).any?
      return true if allowed

      render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden
      false
    end

    def active_workflow?(creative)
      return true if creative.workflow? && creative.archived_at.nil? && @creative.archived_at.nil?

      workflow_error(:not_workflow)
      false
    end

    def editable_workflow_rule?
      @creative.workflow_rule? && @creative.archived_at.nil? &&
        @creative.parent.present?
    end

    def save_workflow_rule(rule, workflow, status)
      payload = params[:workflow_rule]
      payload = payload.to_unsafe_h if payload.is_a?(ActionController::Parameters)
      rule.data = (rule.data || {}).merge("workflow_rule" => payload)
      parsed, errors = Workflow::Rule.parse(rule, validate_liquid: true)
      return render json: { errors: errors }, status: :unprocessable_entity unless parsed

      if rule.save
        initialize_workflow_rule(rule) if status == :created
        render json: Workflow::Editor.new(workflow, Current.user).rule_json(rule), status: status
      else
        render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def initialize_workflow_rule(rule)
      # Initialize inherited access before collaborators receive the new tree row.
      Creatives::PermissionCacheBuilder.rebuild_for_creative(rule)
      rule.broadcast_creative_created
    end

    def workflow_error(key)
      render json: { error: t("collavre.workflow.editor.errors.#{key}") }, status: :unprocessable_entity
    end
  end
end

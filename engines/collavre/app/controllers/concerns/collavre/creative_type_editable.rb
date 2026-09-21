# frozen_string_literal: true

module Collavre
  module CreativeTypeEditable
    extend ActiveSupport::Concern

    included do
      before_action :validate_type_input, only: %i[create update]
      around_action :lock_creative_content, only: %i[update update_metadata update_contexts]
      around_action :lock_rule_authoring, only: %i[create_workflow_rule update_workflow_rule]
    end

    private

    def update_creative_content(base, permitted)
      base.creative_type_placement = @creative
      base.update(permitted)
    end

    def editable_metadata_for(creative)
      data = creative.effective_origin(Set.new).data
      data.is_a?(Hash) ? data.except("markdown_source") : data
    end

    def creative_update_payload(base)
      {
        id: base.id, creative_type: base.creative_type,
        progress: base.progress, progress_html: view_context.render_creative_progress(base),
        has_children: base.children.exists?, content_type: base.data&.dig("content_type"),
        markdown_editor: base.data&.dig("editor")
      }
    end

    def type_input?
      params[:creative].is_a?(ActionController::Parameters) && params[:creative].key?(:creative_type)
    end

    def validate_type_input
      return unless type_input?
      return if params[:creative][:creative_type].is_a?(String)

      render json: { errors: [ t("collavre.creatives.types.errors.invalid") ] }, status: :unprocessable_entity
    end

    def lock_rule_authoring
      workflow = action_name == "create_workflow_rule" ? @creative.effective_origin(Set.new) : @creative.parent
      return yield unless workflow

      workflow.with_lock do
        if action_name == "update_workflow_rule"
          @creative.with_lock { yield }
        else
          yield
        end
      end
    end

    def lock_creative_content
      return if type_input? && !workflow_access?(@creative, :write)

      @creative.effective_origin(Set.new).with_lock do
        yield
        raise ActiveRecord::Rollback if response.status >= 400
      end
      # Comment insertion takes a topic FK lock; release the creative first to
      # avoid reversing the topic -> creative order used by trigger/topic jobs.
      notify_drop_trigger_missing_agent!(@newly_enabled_drop_trigger) if @newly_enabled_drop_trigger
    end
  end
end

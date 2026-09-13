# frozen_string_literal: true

module Collavre
  module CreativeTypeEditable
    extend ActiveSupport::Concern

    included do
      before_action :validate_type_input, only: %i[create update]
      around_action :lock_type_update, only: :update
      around_action :lock_rule_authoring, only: %i[create_workflow_rule update_workflow_rule]
    end

    private

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

      workflow.with_lock { yield }
    end

    def lock_type_update
      return yield unless type_input?
      return unless workflow_access?(@creative, :write)

      @creative.effective_origin(Set.new).with_lock do
        yield
        raise ActiveRecord::Rollback if response.status >= 400
      end
    end
  end
end

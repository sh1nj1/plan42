# frozen_string_literal: true

module Collavre
  class CreativeChangeSetsController < ApplicationController
    VALID_MODES = {
      "draft" => %w[approve reject],
      "applied" => %w[revert restore],
      "reverted" => %w[restore]
    }.freeze

    before_action :set_creative

    def apply
      change_set = CreativeChangeSet.for_creative_scope(@requested_creative).find(params[:id])
      result = valid_mode?(change_set) ? apply_service(change_set).call : invalid_action_result

      render json: payload_for(result), status: response_status(result)
    end

    private

    def apply_service(change_set)
      if change_set.status == "draft"
        return Creatives::DraftChangeSetRejectService.new(
          change_set: change_set, user: Current.user, scope_creative: @requested_creative
        ) if params[:mode] == "reject"

        return Creatives::ChangeSetApplyService.new(
          source: change_set,
          user: Current.user,
          resolutions: resolutions,
          mode: :draft
        )
      end

      return Creatives::ChangeSetRestoreService.new(change_set: change_set, user: Current.user) if params[:mode] == "restore"

      Creatives::ChangeSetRevertService.new(
        change_set: change_set,
        user: Current.user,
        resolutions: resolutions
      )
    end

    def valid_mode?(change_set)
      VALID_MODES.fetch(change_set.status, []).include?(params[:mode])
    end

    def invalid_action_result
      Creatives::ChangeSetApplyService::Result.new(
        status: :invalid_action, change_set: nil, conflicts: [], skipped: []
      )
    end

    def resolutions
      params.fetch(:resolutions, {}).each_pair.filter_map do |creative_id, decision|
        [ creative_id.to_s, decision ] if creative_id.to_s.match?(/\A\d+\z/) && decision.in?(%w[force skip])
      end.to_h
    end

    def set_creative
      @requested_creative = Creative.find(params[:creative_id])
      readable_ids = Creatives::PermissionFilter.new(user: Current.user).readable_ids([ @requested_creative.id ])
      head :forbidden unless readable_ids.include?(@requested_creative.id)
    end

    def payload_for(result)
      {
        status: result.status,
        change_set_id: result.change_set&.id,
        conflicts: result.conflicts,
        skipped: result.skipped,
        message: I18n.t("collavre.creative_history.results.#{result_message_key(result)}")
      }
    end

    def result_message_key(result)
      return :invalid_action if result.status == :invalid_action
      return "restore_#{result.status}" if params[:mode] == "restore"
      return :approved if result.status == :applied && params[:mode] == "approve"

      result.status
    end

    def response_status(result)
      return :conflict if result.status == :conflict
      return :unprocessable_entity unless result.status.in?(%i[applied partial rejected])

      :ok
    end
  end
end

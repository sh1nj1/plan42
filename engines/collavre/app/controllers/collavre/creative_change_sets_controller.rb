# frozen_string_literal: true

module Collavre
  class CreativeChangeSetsController < ApplicationController
    before_action :set_creative

    def apply
      change_set = CreativeChangeSet.for_creative_scope(@creative).find(params[:id])
      result = apply_service(change_set).call

      render json: payload_for(result), status: response_status(result)
    end

    private

    def apply_service(change_set)
      return Creatives::ChangeSetRestoreService.new(change_set: change_set, user: Current.user) if params[:mode] == "restore"

      Creatives::ChangeSetRevertService.new(
        change_set: change_set,
        user: Current.user,
        resolutions: resolutions
      )
    end

    def resolutions
      params.fetch(:resolutions, {}).each_pair.filter_map do |creative_id, decision|
        [ creative_id.to_s, decision ] if creative_id.to_s.match?(/\A\d+\z/) && decision.in?(%w[force skip])
      end.to_h
    end

    def set_creative
      @creative = Creative.find(params[:creative_id]).effective_origin
      head :forbidden unless @creative.has_permission?(Current.user, :read)
    end

    def payload_for(result)
      {
        status: result.status,
        change_set_id: result.change_set&.id,
        conflicts: result.conflicts,
        skipped: result.skipped,
        message: I18n.t("collavre.creative_history.results.#{result.status}")
      }
    end

    def response_status(result)
      return :conflict if result.status == :conflict
      return :unprocessable_entity unless result.status == :applied

      :ok
    end
  end
end

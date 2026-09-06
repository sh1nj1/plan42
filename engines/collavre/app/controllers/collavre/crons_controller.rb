# frozen_string_literal: true

module Collavre
  class CronsController < ApplicationController
    include Collavre::CreativePermissionGuard

    before_action :set_creative
    before_action :require_creative_write!

    def destroy
      task = recurring_tasks.find { |candidate| candidate.key == params[:key] }
      return head :not_found unless task

      task.destroy!
      Crons::ChangeBroadcaster.call(@creative)
      head :no_content
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id]).effective_origin
    end

    def recurring_tasks
      Crons::RecurringTaskIndex.for_creative_family(@creative).tasks_for(@creative.id)
    end
  end
end

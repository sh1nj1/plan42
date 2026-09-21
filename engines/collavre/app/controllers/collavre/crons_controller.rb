# frozen_string_literal: true

module Collavre
  class CronsController < ApplicationController
    include Collavre::CreativePermissionGuard

    before_action :set_creative
    before_action :require_creative_write!

    def update
      task = find_recurring_task
      return head :not_found unless task

      message = params[:message].to_s
      if message.blank?
        return render json: { error: t("collavre.crons.message_required") }, status: :unprocessable_entity
      end

      result = Tools::CronUpdateService.new.call(key: task.key, message: message)
      return render json: result, status: :unprocessable_entity if result[:error]

      render json: { message: message }
    end

    def destroy
      task = find_recurring_task
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

    def find_recurring_task
      recurring_tasks.find { |candidate| candidate.key == params[:key] }
    end
  end
end

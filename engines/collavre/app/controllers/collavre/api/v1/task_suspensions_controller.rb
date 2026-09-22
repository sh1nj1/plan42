# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class TaskSuspensionsController < BaseController
        def create
          task = Task.find_by(id: params[:id])
          return failure(:not_found) unless task
          return failure(:unprocessable_entity) unless params[:reason] == "quota"

          result = nil
          task.agent.with_lock do
            task.with_lock do
              result = authorized?(task) ? suspend_current(task) : :not_found
            end
          end
          return failure(result) unless result == :ok

          render json: { status: task.status, resume_not_before: task.resume_not_before }, status: :ok
        end

        private

        def suspend_current(task)
          return :conflict unless current_generation?(task)
          return :ok if task.status == "suspended" && task.suspend_reason == "quota"
          return :conflict unless task.status == "delegated"

          error = Quota::ExceededError.new(reset_at: Quota::RetryTime.parse(params[:retry_after]))
          Quota::Recovery.suspend!(task, error, expected_generation: params[:execution_generation].to_s) ? :ok : :conflict
        end

        def authorized?(task)
          agent = task&.agent
          agent&.claude_channel_agent? && agent.created_by_id == current_user.id &&
            Creatives::PermissionChecker.current_allowed?(task.creative_id, current_user, :feedback)
        end

        def current_generation?(task)
          expected = task.trigger_event_payload&.dig("execution_generation")
          supplied = params[:execution_generation].to_s
          expected.present? && supplied.present? && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
        end

        def failure(status)
          render json: { error: I18n.t("collavre.quota.suspend_rejected") }, status: status
        end
      end
    end
  end
end

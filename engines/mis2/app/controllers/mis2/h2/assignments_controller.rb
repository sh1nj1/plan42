module Mis2
  module H2
    class AssignmentsController < Mis2::ApplicationController
      def index
        if params[:query].present?
          @users = Mis2::H2::User.search_by_name(params[:query])
        else
          @users = []
        end
      end

      def edit
        @user = Mis2::H2::User.find_by(user_idx: params[:id])
        if @user
          @assignments = Mis2::H2::AssignmentUser.for_user_with_details(@user.user_idx)
        else
          redirect_to mis2.h2_assignments_path, alert: t("mis2.h2.assignments.alerts.user_not_found")
        end
      end

      def validate
        is_conflict = Mis2::H2::AssignmentUser.check_overlap(
          params[:user_idx],
          params[:assignment_user_idx],
          params[:start_date],
          params[:end_date]
        )
        render json: { is_conflict: is_conflict }
      end

      def update
        @user = Mis2::H2::User.find_by(user_idx: params[:user_idx])
        unless @user
            redirect_to mis2.h2_assignments_path, alert: t("mis2.h2.assignments.alerts.user_not_found")
            return
        end

        if params[:start_date] > params[:end_date]
          redirect_to mis2.edit_h2_assignment_path(@user.user_idx), alert: t("mis2.h2.assignments.alerts.date_order_error")
          return
        end


        # Fetch old assignment for logging
        old_assignment = Mis2::H2::AssignmentUser.for_user_with_details(@user.user_idx).find { |a| a.assignment_user_idx.to_s == params[:id].to_s }

        result = Mis2::H2::AssignmentUser.safe_update_dates(
          params[:user_idx],
          params[:id], # assignment_user_idx
          params[:start_date],
          params[:end_date]
        )

        if result.to_i > 0
          if old_assignment
            log_message = t("mis2.activity_log.messages.h2_training_update",
                assignment_name: old_assignment.assignment_name,
                round: old_assignment.round,
                user_name: @user.name,
                user_id: @user.user_idx,
                old_start: old_assignment.assignment_user_start,
                old_end: old_assignment.assignment_user_end,
                new_start: params[:start_date],
                new_end: params[:end_date]
            )

            Mis2::ActivityLog.create(
              user: Current.user,
              user_name: Current.user.name,
              action: "h2_training_update",
              target_type: "Mis2::H2::AssignmentUser",
              target_id: params[:id],
              message: log_message,
              metadata: {
                h2_user_id: @user.user_idx,
                h2_user_name: @user.name,
                h2_assignment_idx: params[:id],
                assignment_name: old_assignment.assignment_name,
                old_start: old_assignment.assignment_user_start,
                old_end: old_assignment.assignment_user_end,
                new_start: params[:start_date],
                new_end: params[:end_date]
              }
            )
          end
          redirect_to mis2.edit_h2_assignment_path(@user.user_idx), notice: t("mis2.h2.assignments.notices.update_success")
        else
          redirect_to mis2.edit_h2_assignment_path(@user.user_idx), alert: t("mis2.h2.assignments.alerts.overlap_error")
        end
      rescue => e
        redirect_to mis2.edit_h2_assignment_path(@user.user_idx), alert: t("mis2.h2.assignments.alerts.general_error", message: e.message)
      end
    end
  end
end

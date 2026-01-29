module Mis2
  module H2
    class UsersController < Mis2::ApplicationController
      def update_organization
        @user = Mis2::H2::User.find_by(user_idx: params[:id])
        unless @user
          render json: { success: false, message: t("mis2.h2.users.user_not_found") }, status: :not_found
          return
        end

        new_organization = Mis2::H2::Organization.find_by(organization_idx: params[:organization_idx])
        unless new_organization
          render json: { success: false, message: t("mis2.h2.users.organization_not_found") }, status: :not_found
          return
        end

        old_organization = @user.organization
        old_organization_name = old_organization&.organization_name || "N/A"

        if @user.update(organization_idx: params[:organization_idx])
          # Create activity log
          log_message = t("mis2.activity_log.messages.h2_organization_update",
            user_name: @user.name,
            user_id: @user.user_idx,
            old_organization: old_organization_name,
            new_organization: new_organization.organization_name
          )

          Mis2::ActivityLog.create(
            user: Current.user,
            user_name: Current.user.name,
            action: "h2_organization_update",
            target_type: "Mis2::H2::User",
            target_id: @user.user_idx.to_s,
            message: log_message,
            metadata: {
              h2_user_id: @user.user_idx,
              h2_user_name: @user.name,
              old_organization_idx: old_organization&.organization_idx,
              old_organization_name: old_organization_name,
              new_organization_idx: new_organization.organization_idx,
              new_organization_name: new_organization.organization_name
            }
          )

          render json: {
            success: true,
            message: t("mis2.h2.users.update_organization_success"),
            organization_name: new_organization.organization_name
          }
        else
          render json: {
            success: false,
            message: t("mis2.h2.users.update_organization_error", message: @user.errors.full_messages.join(", "))
          }, status: :unprocessable_entity
        end
      rescue => e
        render json: {
          success: false,
          message: t("mis2.h2.users.update_organization_error", message: e.message)
        }, status: :internal_server_error
      end
    end
  end
end

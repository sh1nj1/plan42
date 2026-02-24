module Mis2
  module H3
    class OrganizationsController < Mis2::ApplicationController
      include Mis2::Paginatable

      helper_method :filter_params_for_link

      def index
        scope = Mis2::H3::OrganizationAdmin
          .organization_admins
          .with_org_details
          .filter_by_statuses(params[:statuses])
          .search_by_org(params[:query])
          .order("organization_admin.created_at DESC")

        @admins = paginate(scope)
      end

      def approve
        admin = Mis2::H3::OrganizationAdmin.find(params[:id])

        org = nil
        approved = false
        Mis2::H3Record.transaction do
          admin.lock!

          raise ActiveRecord::Rollback unless admin.status == "WAIT"

          org = admin.department.organization
          admin.update!(status: "ACTIVE", modified_at: Time.current, modified_by: Current.user.name)
          org.update!(active_yn: true, modified_at: Time.current, modified_by: Current.user.name)
          approved = true
        end

        unless approved
          redirect_to h3_organizations_path(filter_params),
            alert: t("mis2.h3.organizations.approve_not_wait")
          return
        end

        begin
          Mis2::ActivityLog.create!(
            user: Current.user,
            user_name: Current.user.name,
            action: "h3_organization_approve",
            target_type: "Mis2::H3::OrganizationAdmin",
            target_id: admin.id.to_s,
            message: t("mis2.activity_log.messages.h3_organization_approve",
              org_name: org.name,
              org_code: org.code,
              admin_name: admin.name,
              admin_id: admin.id
            ),
            metadata: {
              "h3_admin_id" => admin.id,
              "h3_admin_name" => admin.name,
              "h3_org_id" => org.id,
              "h3_org_name" => org.name,
              "h3_org_code" => org.code,
              "undoable" => false
            }
          )
        rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
          Rails.logger.error("[H3 Approve] ActivityLog failed for admin_id=#{admin.id}: #{e.message}")
        end

        redirect_to h3_organizations_path(filter_params),
          notice: t("mis2.h3.organizations.approve_success")
      rescue ActiveRecord::RecordNotFound
        redirect_to h3_organizations_path(filter_params),
          alert: t("mis2.h3.organizations.not_found")
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
        Rails.logger.error("[H3 Approve] id=#{params[:id]} error=#{e.class}: #{e.message}")
        redirect_to h3_organizations_path(filter_params),
          alert: t("mis2.h3.organizations.approve_error")
      end

      private

      def filter_params
        params.permit(:query, :page, statuses: []).to_h.compact_blank
      end

      def filter_params_for_link
        filter_params.except("page")
      end
    end
  end
end

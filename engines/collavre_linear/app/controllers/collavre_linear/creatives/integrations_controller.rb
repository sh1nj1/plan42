# frozen_string_literal: true

module CollavreLinear
  module Creatives
    class IntegrationsController < ApplicationController
      include Collavre::IntegrationSetup
      include Collavre::IntegrationPermission

      before_action :set_creative
      before_action :set_origin
      before_action :ensure_read_permission
      before_action :ensure_admin_permission, only: %i[create destroy resync]

      # POST /linear/creatives/:creative_id/integration
      #
      # Links a Creative subtree to a Linear team + project, provisions a
      # webhook for the team, and enqueues an initial full export.
      def create
        account = Current.user.linear_account
        unless account
          render json: { error: I18n.t("collavre_linear.errors.not_connected") },
                 status: :unprocessable_entity
          return
        end

        team_id          = params[:team_id].to_s.presence
        linear_project_id = params[:linear_project_id].to_s.presence

        unless team_id && linear_project_id
          render json: { error: I18n.t("collavre_linear.errors.missing_params") },
                 status: :unprocessable_entity
          return
        end

        link = @origin.linear_project_links.find_or_initialize_by(
          account:           account,
          linear_project_id: linear_project_id
        )
        link.team_id = team_id
        link.save!

        provision_result = CollavreLinear::WebhookProvisioner.ensure_for(
          project_link: link,
          webhook_url:  linear_webhook_url
        )

        # Existing descendants never fire after-commit callbacks during linking,
        # so enqueue an outbound export for the whole subtree — otherwise a
        # populated tree would only create the root Linear issue. Idempotent:
        # the exporter skips unchanged content via its content hash.
        @origin.self_and_descendants.ids.each do |creative_id|
          CollavreLinear::OutboundSyncJob.perform_later(creative_id)
        end

        # Webhook provisioning failure must NOT fail the request — the link and
        # outbound sync still work — but it MUST be surfaced: without a webhook,
        # inbound sync is silently disabled (usually a missing Linear admin
        # permission on the OAuth grant).
        webhook_provisioned = provision_result != :failed
        response_body = {
          success:             true,
          project_link:        serialize_link(link),
          webhook_provisioned: webhook_provisioned
        }
        unless webhook_provisioned
          response_body[:warning] = I18n.t("collavre_linear.integration.webhook_provision_failed")
        end

        render json: response_body
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /linear/creatives/:creative_id/integration
      #
      # Unlinks the Creative from its Linear project and deregisters the
      # remote webhook at Linear (best-effort; unlink succeeds even if the
      # API call fails).
      def destroy
        account = Current.user.linear_account
        unless account
          render json: { error: I18n.t("collavre_linear.errors.not_connected") },
                 status: :unprocessable_entity
          return
        end

        link = @origin.linear_project_links.find_by(account: account)
        unless link
          render json: { error: I18n.t("collavre_linear.errors.not_found") },
                 status: :not_found
          return
        end

        CollavreLinear::WebhookProvisioner.deregister(project_link: link)
        link.destroy!

        render json: { success: true }
      end

      # POST /linear/creatives/:creative_id/integration/resync
      #
      # Re-enqueues a full outbound export for the subtree root.
      def resync
        account = Current.user.linear_account
        unless account
          render json: { error: I18n.t("collavre_linear.errors.not_connected") },
                 status: :unprocessable_entity
          return
        end

        unless @origin.linear_project_links.where(account: account).exists?
          render json: { error: I18n.t("collavre_linear.errors.not_found") },
                 status: :not_found
          return
        end

        CollavreLinear::OutboundSyncJob.perform_later(@origin.id)

        render json: { success: true, message: I18n.t("collavre_linear.integration.resync_started") }
      end

      private

      def integration_forbidden_message
        I18n.t("collavre_linear.errors.forbidden")
      end

      def serialize_link(link)
        {
          id:                link.id,
          team_id:           link.team_id,
          linear_project_id: link.linear_project_id,
          sync_state:        link.sync_state,
          webhook_id:        link.webhook_id
        }
      end
    end
  end
end

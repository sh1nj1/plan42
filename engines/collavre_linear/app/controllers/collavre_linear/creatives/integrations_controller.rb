# frozen_string_literal: true

module CollavreLinear
  module Creatives
    class IntegrationsController < ApplicationController
      include Collavre::IntegrationSetup
      include Collavre::IntegrationPermission

      before_action :set_creative
      before_action :set_origin
      before_action :ensure_read_permission
      before_action :ensure_admin_permission, only: %i[create destroy resync update_secret options]

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

        # Reject linking inside/around an already-linked subtree. A second
        # ProjectLink on an ancestor/descendant would sync against the wrong
        # project: IssueLink is unique per Creative and the exporter resolves
        # both ProjectLink and IssueLink per creative WITHOUT account scope, so
        # the new project would silently update the old project's issues. The
        # check must span ALL accounts — a second admin with their own Linear
        # account could otherwise hijack the subtree. Re-linking @origin to the
        # SAME project stays idempotent (find_or_initialize_by below).
        overlapping_ids =
          (@origin.self_and_ancestors.ids + @origin.self_and_descendants.ids).uniq - [ @origin.id ]
        overlapping = overlapping_ids.any? &&
          CollavreLinear::ProjectLink.where(creative_id: overlapping_ids).exists?

        # @origin may only carry the idempotent re-link target (same account AND
        # same project). Any other existing link on @origin conflicts: a
        # different project (the exporter would keep updating the old issue), or
        # the same subtree claimed by another account. The ancestor/descendant
        # check above excludes @origin, so guard @origin explicitly here.
        origin_conflict = @origin.linear_project_links
                                 .where.not(account: account, linear_project_id: linear_project_id)
                                 .exists?

        # One Linear project maps to exactly one Collavre root. Inbound webhooks
        # resolve the project with an UNSCOPED find_by(linear_project_id:), so a
        # second ProjectLink for the same project on a DISJOINT creative (not an
        # ancestor/descendant, so the overlap check above misses it) would make
        # imports/updates land on whichever row the DB returns while both roots
        # export into it. Reject globally; re-linking @origin stays idempotent.
        project_taken = CollavreLinear::ProjectLink
                          .where(linear_project_id: linear_project_id)
                          .where.not(creative_id: @origin.id)
                          .exists?

        if overlapping || origin_conflict || project_taken
          render json: { error: I18n.t("collavre_linear.errors.overlapping_link") },
                 status: :unprocessable_entity
          return
        end

        link = @origin.linear_project_links.find_or_initialize_by(
          account:           account,
          linear_project_id: linear_project_id
        )
        link.team_id = team_id
        begin
          link.save!
        rescue ActiveRecord::RecordNotUnique
          # Race-safe backstop for the project_taken check above: the check is
          # check-then-save, so two concurrent requests can both pass it; the
          # linear_project_id unique index rejects the loser's insert. Surface
          # the same conflict instead of a 500.
          render json: { error: I18n.t("collavre_linear.errors.overlapping_link") },
                 status: :unprocessable_entity
          return
        end

        # Existing descendants never fire after-commit callbacks during linking,
        # so enqueue an outbound export for the whole subtree — otherwise a
        # populated tree would only create the root Linear issue. Idempotent:
        # the exporter skips unchanged content via its content hash.
        enqueue_subtree_sync

        # Inbound sync needs a webhook Linear can't auto-provision (app actors
        # lack the admin scope), so the admin sets it up by hand and pastes the
        # secret Linear generates via update_secret. The modal shows that guide.
        render json: { success: true, project_link: serialize_link(link) }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /linear/creatives/:creative_id/integration
      #
      # Unlinks the Creative from its Linear project. The webhook is set up by
      # hand in Linear (we never learn its id), so there is nothing to
      # deregister here — the admin removes it in Linear's settings if desired.
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

        link.destroy!

        render json: { success: true }
      end

      # POST /linear/creatives/:creative_id/integration/resync
      #
      # Re-enqueues a full outbound export for the whole subtree. Mirrors the
      # create path: enqueuing only the root would never recover stale/missing
      # descendant issues. The ParentNotExportedError + retry_on deferral in
      # OutboundSyncJob protects against parent-before-child races, so enqueuing
      # the full subtree is safe.
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

        enqueue_subtree_sync

        render json: { success: true, message: I18n.t("collavre_linear.integration.resync_started") }
      end

      # POST /linear/creatives/:creative_id/integration/secret
      #
      # Store the signing secret the admin copied from Linear's webhook settings.
      # Linear owns the secret (it generates one per webhook and won't let us pick
      # it), so the admin pastes it here and we propagate it to the team's sibling
      # links — the one value all of the team's deliveries verify against.
      def update_secret
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

        secret = params[:webhook_secret].to_s.strip
        if secret.blank?
          render json: { error: I18n.t("collavre_linear.errors.missing_secret") },
                 status: :unprocessable_entity
          return
        end

        link.update_webhook_secret!(secret)

        render json: { success: true }
      end

      # GET /linear/creatives/:creative_id/integration/options
      #
      # Teams and projects the connected account can see, so the link modal can
      # offer dropdowns instead of asking the user to type raw Linear IDs.
      def options
        account = Current.user.linear_account
        unless account
          render json: { error: I18n.t("collavre_linear.errors.not_connected") },
                 status: :unprocessable_entity
          return
        end

        client = CollavreLinear::Client.new(account)
        render json: { teams: client.list_teams, projects: client.list_projects }
      rescue CollavreLinear::Client::Error => e
        # Surface the Linear-side failure (expired token, revoked scope) instead
        # of leaving the dropdowns silently empty.
        render json: { error: e.message }, status: :bad_gateway
      end

      private

      # Enqueue an outbound export for every Creative in the @origin subtree.
      # Shared by create (initial link) and resync so both cover descendants.
      def enqueue_subtree_sync
        @origin.self_and_descendants.ids.each do |creative_id|
          CollavreLinear::OutboundSyncJob.perform_later(creative_id)
        end
      end

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

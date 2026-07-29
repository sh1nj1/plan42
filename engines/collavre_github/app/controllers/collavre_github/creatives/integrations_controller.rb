module CollavreGithub
  module Creatives
    class IntegrationsController < ApplicationController
      include Collavre::IntegrationSetup
      include Collavre::IntegrationPermission

      before_action :set_creative
      before_action :set_origin
      before_action :ensure_read_permission
      before_action :ensure_admin_permission, only: [ :show, :update, :resync ]

      def show
        account = Current.user.github_account
        links = linked_repository_links(account)

        # Also include repositories linked by other users for this creative
        all_links = @creative.github_repository_links.includes(:github_account)
        all_repositories = all_links.map(&:repository_full_name).uniq

        render json: {
          connected: account.present?,
          account: account && {
            login: account.login,
            name: account.name,
            avatar_url: account.avatar_url
          },
          selected_repositories: links.map(&:repository_full_name),
          all_repositories: all_repositories,
          webhooks: serialize_webhooks(links),
          markdown_sync: links.each_with_object({}) { |l, h|
            h[l.repository_full_name] = {
              enabled: l.markdown_sync_enabled?,
              last_synced_at: l.last_synced_at,
              sync_branch: l.markdown_sync_branch
            }
          }
        }
      end

      def update
        account = Current.user.github_account
        unless account
          render json: { error: I18n.t("collavre_github.errors.not_connected") }, status: :unprocessable_entity
          return
        end

        integration_attributes = integration_params
        repositories = Array(integration_attributes[:repositories]).map(&:to_s).uniq
        existing_by_name = linked_repository_links(account)
          .index_by { |link| link.repository_full_name.downcase }
        client = CollavreGithub::Client.new(account)
        identities = {}
        verified_repository_ids = {}
        repositories.each do |full_name|
          normalized_name = full_name.downcase
          existing = existing_by_name[normalized_name]
          next if existing && existing.repository_id.blank?

          identity = client.repository_identity(full_name)
          unless identity&.id.present? && identity&.full_name.present?
            render json: { error: I18n.t("collavre_github.setup.save_error") },
                   status: :unprocessable_entity
            return
          end

          if existing && existing.repository_id.to_s != identity.id.to_s
            Rails.logger.warn(
              "[CollavreGithub] skipping webhook provisioning for stale link #{existing.id}: " \
              "#{full_name} resolves to repository #{identity.id}, not #{existing.repository_id}"
            )
            next
          end

          identities[normalized_name] = identity unless existing
          verified_repository_ids[normalized_name] = identity.id
          verified_repository_ids[identity.full_name.downcase] = identity.id
        end

        links = nil
        CollavreGithub::RepositoryLink.transaction do
          selected_names = repositories.map(&:downcase)
          current_links = linked_repository_links(account)
          if selected_names.empty?
            current_links.delete_all
          else
            current_links
              .where.not("LOWER(repository_full_name) IN (?)", selected_names)
              .delete_all
          end

          repositories.each do |full_name|
            next if existing_by_name.key?(full_name.downcase)

            identity = identities.fetch(full_name.downcase)
            @origin.github_repository_links.create!(
              github_account: account,
              repository_full_name: identity.full_name,
              repository_id: identity.id
            )
          end

          links = linked_repository_links(account).to_a
        end

        # Handle markdown sync toggle BEFORE webhook provisioning
        # so events_for() sees the updated markdown_sync_enabled state
        markdown_sync = integration_attributes[:markdown_sync]
        if markdown_sync.is_a?(ActionController::Parameters) || markdown_sync.is_a?(Hash)
          links.each do |link|
            repo = link.repository_full_name
            next unless markdown_sync.key?(repo)

            enabled = ActiveModel::Type::Boolean.new.cast(markdown_sync[repo])
            was_enabled = link.markdown_sync_enabled?
            link.update!(markdown_sync_enabled: enabled)

            if enabled && !was_enabled
              CollavreGithub::InitialMarkdownSyncJob.perform_later(link.id)
            end
          end
        end

        # Provision only identities positively verified before the transaction.
        # Existing name-only links may predate stable repository identities,
        # while an ID-backed link can still carry a stale name after a missed
        # rename. Neither may mutate whatever repository owns that name now.
        # Legacy links are upgraded only by WebhookReprovisioner after their
        # recorded hook id proves the live identity.
        provisionable_links = links.select do |link|
          verified_id = verified_repository_ids[link.repository_full_name.downcase]
          verified_id.present? &&
            link.repository_id.present? &&
            verified_id.to_s == link.repository_id.to_s
        end
        if provisionable_links.present?
          CollavreGithub::WebhookProvisioner.ensure_for_links(
            account: account,
            links: provisionable_links,
            webhook_url: github_webhook_url
          )
        end

        render json: {
          success: true,
          selected_repositories: links.map(&:repository_full_name),
          webhooks: serialize_webhooks(links),
          markdown_sync: links.each_with_object({}) { |l, h|
            h[l.repository_full_name] = {
              enabled: l.markdown_sync_enabled?,
              last_synced_at: l.last_synced_at,
              sync_branch: l.markdown_sync_branch
            }
          }
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue Octokit::Error, Faraday::Error => e
        Rails.logger.warn(
          "[CollavreGithub] repository identity lookup failed while saving integration: " \
          "#{e.class}: #{e.message}"
        )
        render json: { error: I18n.t("collavre_github.setup.save_error") },
               status: :unprocessable_entity
      end

      def resync
        account = Current.user.github_account
        unless account
          render json: { error: I18n.t("collavre_github.errors.not_connected") }, status: :unprocessable_entity
          return
        end

        repo = params[:repository]
        link = linked_repository_links(account).find_by(repository_full_name: repo)
        unless link&.markdown_sync_enabled?
          render json: { error: I18n.t("collavre_github.markdown_sync.not_enabled") }, status: :unprocessable_entity
          return
        end

        # Archive existing synced tree and re-import
        if link.markdown_root_creative
          link.markdown_root_creative.archive! if link.markdown_root_creative.respond_to?(:archive!)
          link.update!(markdown_root_creative_id: nil)
        end

        CollavreGithub::InitialMarkdownSyncJob.perform_later(link.id)
        render json: { success: true, message: I18n.t("collavre_github.markdown_sync.resync_started") }
      end

      def destroy
        unless @creative.has_permission?(Current.user, :write)
          render json: { error: integration_forbidden_message }, status: :forbidden
          return
        end

        account = Current.user.github_account
        unless account
          render json: { error: I18n.t("collavre_github.errors.not_connected") }, status: :unprocessable_entity
          return
        end

        repositories = Array(params[:repositories]).filter_map { |value| value.to_s.presence }
        repository = params[:repository].presence || params[:repository_full_name].presence

        scope = linked_repository_links(account)

        removed_repositories = []

        if repositories.present?
          links_to_remove = scope.where(repository_full_name: repositories).to_a
          missing_repositories = repositories - links_to_remove.map(&:repository_full_name)
          if missing_repositories.present?
            render json: { error: I18n.t("collavre_github.errors.not_found") }, status: :not_found
            return
          end

          CollavreGithub::RepositoryLink.transaction do
            removed_repositories = links_to_remove.map(&:repository_full_name)
            links_to_remove.each(&:destroy!)
          end
        elsif repository
          link = scope.find_by(repository_full_name: repository)
          unless link
            render json: { error: I18n.t("collavre_github.errors.not_found") }, status: :not_found
            return
          end

          CollavreGithub::RepositoryLink.transaction do
            removed_repositories = [ link.repository_full_name ]
            link.destroy!
          end
        else
          CollavreGithub::RepositoryLink.transaction do
            removed_repositories = scope.pluck(:repository_full_name)
            scope.destroy_all
          end
        end

        if removed_repositories.present?
          CollavreGithub::WebhookProvisioner.remove_for_repositories(
            account: account,
            repositories: removed_repositories,
            webhook_url: github_webhook_url
          )
        end

        links = linked_repository_links(account)

        render json: {
          success: true,
          selected_repositories: links.pluck(:repository_full_name),
          webhooks: serialize_webhooks(links)
        }
      end

      private

      def integration_forbidden_message
        I18n.t("collavre_github.errors.forbidden")
      end

      def linked_repository_links(account)
        return CollavreGithub::RepositoryLink.none unless account

        @origin.github_repository_links.where(github_account: account)
      end

      def integration_params
        params.permit(repositories: [], markdown_sync: {})
      end

      def serialize_webhooks(links)
        return {} if links.blank?

        url = github_webhook_url
        links.each_with_object({}) do |link, hash|
          hash[link.repository_full_name] = {
            url: url,
            secret: link.webhook_secret
          }
        end
      end
    end
  end
end

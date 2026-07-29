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
        markdown_sync = integration_attributes[:markdown_sync]
        repositories = Array(integration_attributes[:repositories]).map(&:to_s).uniq
        existing_links = linked_repository_links(account).to_a
        existing_by_name = existing_links.index_by { |link| link.repository_full_name.downcase }
        client = CollavreGithub::Client.new(account)
        identities = {}
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
              "[CollavreGithub] rejecting integration save for stale link #{existing.id}: " \
              "#{full_name} resolves to repository #{identity.id}, not #{existing.repository_id}"
            )
            render json: { error: I18n.t("collavre_github.setup.save_error") },
                   status: :unprocessable_entity
            return
          end

          identities[normalized_name] = identity
          identities[identity.full_name.downcase] = identity
        end

        repositories = repositories.group_by do |full_name|
          normalized_name = full_name.downcase
          existing = existing_by_name[normalized_name]
          identity = identities[normalized_name]
          repository_id = identity&.id || existing&.repository_id

          if repository_id.present?
            [ :id, repository_id.to_s ]
          else
            canonical_name = identity&.full_name || existing&.repository_full_name || full_name
            [ :name, canonical_name.downcase ]
          end
        end.values.map do |aliases|
          identity = aliases.filter_map { |full_name| identities[full_name.downcase] }.first
          existing = aliases.filter_map { |full_name| existing_by_name[full_name.downcase] }.first
          identity&.full_name || existing&.repository_full_name || aliases.first
        end

        # Reject deterministic canonical-name collisions before any hook is
        # touched. A NULL or different-id row is not the verified repository
        # and must never replace its old-name exact-id anchor.
        repositories.each do |full_name|
          identity = identities[full_name.downcase]
          next unless identity

          canonical = @origin.github_repository_links
            .where("LOWER(repository_full_name) = ?", identity.full_name.downcase)
            .first
          next unless canonical
          next if canonical.repository_id.to_s == identity.id.to_s

          render json: { error: I18n.t("collavre_github.setup.save_error") },
                 status: :unprocessable_entity
          return
        end

        # A legacy NULL-id row may point at a repository name GitHub has since
        # reassigned. Enabling import would read that unrelated repository and
        # archive the creative's existing sync tree before identity is proven.
        if markdown_sync.is_a?(ActionController::Parameters) || markdown_sync.is_a?(Hash)
          unsafe_legacy_enable = repositories.any? do |full_name|
            link = existing_by_name[full_name.downcase]
            next false unless link && link.repository_id.blank?
            next false unless markdown_sync.key?(full_name)

            ActiveModel::Type::Boolean.new.cast(markdown_sync[full_name])
          end
          if unsafe_legacy_enable
            render json: { error: I18n.t("collavre_github.setup.save_error") },
                   status: :unprocessable_entity
            return
          end
        end

        # Provision each verified repository in its own transaction. If a
        # later repository fails, earlier successful GitHub mutations retain
        # their matching local link/secret instead of being rolled back into a
        # ghost-hook state.
        repositories.each do |full_name|
          identity = identities[full_name.downcase]
          next unless identity

          repository_failed = false
          sync_job_link_id = nil
          CollavreGithub::RepositoryLink.transaction(requires_new: true) do
            anchor = linked_repository_links(account)
              .where(repository_id: identity.id)
              .order(:id)
              .first
            link = if anchor
              synchronized = CollavreGithub::RepositoryIdentitySynchronizer.call(
                anchor: anchor,
                repository_id: identity.id,
                full_name: identity.full_name,
                trusted_secret: anchor.webhook_secret
              )
              synchronized.find do |candidate|
                candidate.creative_id == @origin.id &&
                  candidate.repository_id.to_s == identity.id.to_s
              end
            else
              @origin.github_repository_links
                .where("LOWER(repository_full_name) = ?", identity.full_name.downcase)
                .where(repository_id: identity.id)
                .first
            end

            unless link
              link = @origin.github_repository_links.create!(
                github_account: account,
                repository_full_name: identity.full_name,
                repository_id: identity.id
              )
            end
            link.update!(github_account: account) if link.github_account_id != account.id

            if markdown_sync.is_a?(ActionController::Parameters) || markdown_sync.is_a?(Hash)
              if markdown_sync.key?(identity.full_name)
                enabled = ActiveModel::Type::Boolean.new.cast(markdown_sync[identity.full_name])
                was_enabled = link.markdown_sync_enabled?
                link.update!(markdown_sync_enabled: enabled)
                sync_job_link_id = link.id if enabled && !was_enabled
              end
            end

            results = CollavreGithub::WebhookProvisioner.ensure_for_links(
              account: account,
              links: [ link ],
              webhook_url: github_webhook_url,
              force_hook_refresh: true
            )
            if results.any? { |_candidate, status| status == :failed }
              repository_failed = true
              raise ActiveRecord::Rollback
            end
          end

          if repository_failed
            render json: { error: I18n.t("collavre_github.setup.save_error") },
                   status: :unprocessable_entity
            return
          end

          if sync_job_link_id
            CollavreGithub::InitialMarkdownSyncJob.perform_later(sync_job_link_id)
          end
        end

        links = nil
        sync_job_link_ids = []
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

          links = linked_repository_links(account).to_a

          # Enqueue the initial import only after selection and every hook
          # provision have succeeded.
          if markdown_sync.is_a?(ActionController::Parameters) || markdown_sync.is_a?(Hash)
            links.each do |link|
              repo = link.repository_full_name
              next unless markdown_sync.key?(repo)

              enabled = ActiveModel::Type::Boolean.new.cast(markdown_sync[repo])
              was_enabled = link.markdown_sync_enabled?
              link.update!(markdown_sync_enabled: enabled)

              sync_job_link_ids << link.id if enabled && !was_enabled
            end
          end
        end

        sync_job_link_ids.each { |link_id| CollavreGithub::InitialMarkdownSyncJob.perform_later(link_id) }

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

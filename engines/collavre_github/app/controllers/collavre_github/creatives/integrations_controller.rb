module CollavreGithub
  module Creatives
    class IntegrationsController < ApplicationController
      include Collavre::IntegrationPermission

      before_action :set_creative
      before_action :set_origin
      before_action :ensure_read_permission
      before_action :ensure_admin_permission, only: [ :show, :update ]

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
          webhooks: serialize_webhooks(links)
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

        links = nil

        CollavreGithub::RepositoryLink.transaction do
          linked_repository_links(account)
            .where.not(repository_full_name: repositories)
            .delete_all

          repositories.each do |full_name|
            @origin.github_repository_links.find_or_create_by!(
              github_account: account,
              repository_full_name: full_name
            )
          end

          links = linked_repository_links(account).to_a
        end

        CollavreGithub::WebhookProvisioner.ensure_for_links(
          account: account,
          links: links,
          webhook_url: github_webhook_url
        ) if links.present?

        render json: {
          success: true,
          selected_repositories: links.map(&:repository_full_name),
          webhooks: serialize_webhooks(links)
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
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

      def set_creative
        @creative = Collavre::Creative.find(params[:creative_id])
      end

      def set_origin
        @origin = @creative.effective_origin
      end

      def integration_forbidden_message
        I18n.t("collavre_github.errors.forbidden")
      end

      def linked_repository_links(account)
        return CollavreGithub::RepositoryLink.none unless account

        @origin.github_repository_links.where(github_account: account)
      end

      def integration_params
        params.permit(repositories: [])
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

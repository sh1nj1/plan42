module Creatives
  class GithubIntegrationsController < ApplicationController
    before_action :set_creative
    before_action :ensure_read_permission
    before_action :ensure_admin_permission, only: [ :show, :update ]

    def show
      account = Current.user.github_account
      links = linked_repository_links(account)

      render json: {
        connected: account.present?,
        account: account && {
          login: account.login,
          name: account.name,
          avatar_url: account.avatar_url
        },
        selected_repositories: links.map(&:repository_full_name),
        webhooks: serialize_webhooks(links),
        github_gemini_prompt: @creative.github_gemini_prompt_template
      }
    end

    def update
      account = Current.user.github_account
      unless account
        render json: { error: "not_connected" }, status: :unprocessable_entity
        return
      end

      integration_attributes = integration_params
      repositories = Array(integration_attributes[:repositories]).map(&:to_s).uniq
      prompt_param = integration_attributes[:github_gemini_prompt] if integration_attributes.key?(:github_gemini_prompt)

      links = nil

      GithubRepositoryLink.transaction do
        linked_repository_links(account)
          .where.not(repository_full_name: repositories)
          .delete_all

        repositories.each do |full_name|
          @creative.github_repository_links.find_or_create_by!(
            github_account: account,
            repository_full_name: full_name
          )
        end

        links = linked_repository_links(account).to_a

        if prompt_param
          @creative.update!(github_gemini_prompt: prompt_param.presence)
        end
      end

      Github::WebhookProvisioner.ensure_for_links(
        account: account,
        links: links,
        webhook_url: github_webhook_url
      ) if links.present?

      render json: {
        success: true,
        selected_repositories: links.map(&:repository_full_name),
        webhooks: serialize_webhooks(links),
        github_gemini_prompt: @creative.github_gemini_prompt_template
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def destroy
      unless @creative.has_permission?(Current.user, :write)
        render json: { error: "forbidden" }, status: :forbidden
        return
      end

      account = Current.user.github_account
      unless account
        render json: { error: "not_connected" }, status: :unprocessable_entity
        return
      end

      repository = params[:repository].presence || params[:repository_full_name].presence

      scope = linked_repository_links(account)

      removed_repositories = []

      if repository
        link = scope.find_by(repository_full_name: repository)
        unless link
          render json: { error: "not_found" }, status: :not_found
          return
        end

        GithubRepositoryLink.transaction do
          removed_repositories = [link.repository_full_name]
          link.destroy!
        end
      else
        GithubRepositoryLink.transaction do
          removed_repositories = scope.pluck(:repository_full_name)
          scope.destroy_all
        end
      end

      if removed_repositories.present?
        Github::WebhookProvisioner.remove_for_repositories(
          account: account,
          repositories: removed_repositories,
          webhook_url: github_webhook_url
        )
      end

      links = linked_repository_links(account)

      render json: {
        success: true,
        selected_repositories: links.pluck(:repository_full_name),
        webhooks: serialize_webhooks(links),
        github_gemini_prompt: @creative.github_gemini_prompt_template
      }
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id])
    end

    def ensure_read_permission
      return if @creative.has_permission?(Current.user, :read)

      render json: { error: "forbidden" }, status: :forbidden
    end

    def ensure_admin_permission
      return if @creative.has_permission?(Current.user, :admin)

      render json: { error: "forbidden" }, status: :forbidden
    end

    def linked_repository_links(account)
      return GithubRepositoryLink.none unless account

      @creative.github_repository_links.where(github_account: account)
    end

    def integration_params
      params.permit(:github_gemini_prompt, repositories: [])
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

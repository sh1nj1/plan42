module Creatives
  class GithubIntegrationsController < ApplicationController
    before_action :set_creative
    before_action :ensure_read_permission

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
        prompt: current_prompt
      }
    end

    def update
      unless @creative.has_permission?(Current.user, :write)
        render json: { error: "forbidden" }, status: :forbidden
        return
      end

      account = Current.user.github_account
      unless account
        render json: { error: "not_connected" }, status: :unprocessable_entity
        return
      end

      repositories = Array(params[:repositories]).map(&:to_s).uniq

      links = nil
      prompt_param = params.key?(:prompt) ? params[:prompt].to_s : nil
      base_creative = @creative.effective_origin

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

        if params.key?(:prompt)
          base_creative.update!(github_gemini_prompt: prompt_param.presence)
        end
      end

      Github::WebhookProvisioner.ensure_for_links(
        account: account,
        links: links,
        webhook_url: github_webhook_url
      ) if links.present?

      prompt_response = prompt_param.presence || base_creative.github_gemini_prompt.presence ||
        Github::PullRequestAnalyzer::DEFAULT_PROMPT_INSTRUCTIONS

      render json: {
        success: true,
        selected_repositories: links.map(&:repository_full_name),
        webhooks: serialize_webhooks(links),
        prompt: prompt_response
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id])
    end

    def ensure_read_permission
      return if @creative.has_permission?(Current.user, :read)

      render json: { error: "forbidden" }, status: :forbidden
    end

    def linked_repository_links(account)
      return GithubRepositoryLink.none unless account

      @creative.github_repository_links.where(github_account: account)
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

    def current_prompt
      base = @creative.effective_origin
      base.github_gemini_prompt.presence || Github::PullRequestAnalyzer::DEFAULT_PROMPT_INSTRUCTIONS
    end
  end
end

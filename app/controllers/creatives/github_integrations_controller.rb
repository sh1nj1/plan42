module Creatives
  class GithubIntegrationsController < ApplicationController
    before_action :set_creative
    before_action :ensure_read_permission

    def show
      account = Current.user.github_account
      selected = if account
        @creative.github_repository_links.where(github_account: account).pluck(:repository_full_name)
      else
        []
      end

      render json: {
        connected: account.present?,
        account: account && {
          login: account.login,
          name: account.name,
          avatar_url: account.avatar_url
        },
        selected_repositories: selected
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

      GithubRepositoryLink.transaction do
        @creative.github_repository_links.where(github_account: account)
                 .where.not(repository_full_name: repositories).delete_all
        repositories.each do |full_name|
          @creative.github_repository_links.find_or_create_by!(
            github_account: account,
            repository_full_name: full_name
          )
        end
      end

      render json: { success: true, selected_repositories: repositories }
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
  end
end

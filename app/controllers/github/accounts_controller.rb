module Github
  class AccountsController < ApplicationController
    before_action :require_account

    def show
      render json: serialize_account(Current.user.github_account)
    end

    def organizations
      orgs = github_client.organizations.map do |org|
        {
          id: org[:id] || org["id"],
          login: org[:login] || org["login"],
          name: org[:name] || org["name"] || (org[:login] || org["login"]),
          type: org[:type] || org["type"]
        }
      end

      user_org = {
        id: Current.user.github_account.github_uid,
        login: Current.user.github_account.login,
        name: Current.user.github_account.name.presence || Current.user.github_account.login,
        type: "User"
      }

      render json: { organizations: [ user_org ] + orgs }
    rescue Octokit::Unauthorized
      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def repositories
      organization = params[:organization]
      creative = params[:creative_id].present? ? Creative.find_by(id: params[:creative_id]) : nil
      selected = if creative
        creative.github_repository_links.where(github_account: Current.user.github_account)
                .pluck(:repository_full_name)
      else
        []
      end

      repos = fetch_repositories(organization).map do |repo|
        full_name = repo[:full_name] || repo["full_name"]
        {
          id: repo[:id] || repo["id"],
          name: repo[:name] || repo["name"],
          full_name: full_name,
          selected: selected.include?(full_name)
        }
      end

      render json: { repositories: repos }
    rescue Octokit::NotFound
      render json: { error: "not_found" }, status: :not_found
    end

    private

    def serialize_account(account)
      {
        login: account.login,
        name: account.name,
        avatar_url: account.avatar_url
      }
    end

    def require_account
      return if Current.user.github_account

      render json: { connected: false, error: "not_connected" }, status: :unprocessable_entity
    end

    def github_client
      @github_client ||= Github::Client.new(Current.user.github_account)
    end

    def fetch_repositories(organization)
      if organization.blank? || organization == Current.user.github_account.login
        github_client.repositories_for_authenticated_user
      else
        github_client.repositories_for_organization(organization)
      end
    end
  end
end

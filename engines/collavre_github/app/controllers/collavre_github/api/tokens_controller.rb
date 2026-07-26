# frozen_string_literal: true

module CollavreGithub
  module Api
    class TokensController < BaseController
      # GET /github/api/token?creative_id=123
      #
      # Returns the requesting user's GitHub OAuth token if:
      #   1. The user has write+ permission on the given creative
      #   2. A GitHub integration (RepositoryLink) exists on the creative or one of its ancestors
      #   3. The user has a linked GithubAccount with a token
      #
      # Response: { token: "gho_xxx", repo: "owner/repo" }
      def show
        creative = Collavre::Creative.find_by(id: params[:creative_id])
        unless creative
          render json: { error: "Creative not found" }, status: :not_found
          return
        end

        # 1. Check write+ permission on the creative
        unless creative.has_permission?(current_api_user, :write)
          render json: { error: "Insufficient permission" }, status: :forbidden
          return
        end

        # 2. Find GitHub integration in the creative's ancestor chain
        origin = creative.effective_origin
        ancestor_ids = origin.self_and_ancestors.pluck(:id)
        link = CollavreGithub::RepositoryLink
          .where(creative_id: ancestor_ids)
          .first

        unless link
          render json: { error: "No GitHub integration found" }, status: :not_found
          return
        end

        # 3. Get the requesting user's own GitHub account token
        account = CollavreGithub::Account.find_by(user: current_api_user)
        unless account&.token.present?
          render json: { error: "GitHub account not linked" }, status: :not_found
          return
        end

        render json: { token: account.token, repo: link.repository_full_name }
      end
    end
  end
end

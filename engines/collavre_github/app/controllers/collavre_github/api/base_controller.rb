# frozen_string_literal: true

module CollavreGithub
  module Api
    class BaseController < ActionController::API
      before_action :authenticate!

      private

      def authenticate!
        token = extract_bearer_token
        if token.blank?
          render json: { error: "Missing authentication token" }, status: :unauthorized
          return
        end

        unless authenticate_oauth(token)
          render json: { error: "Invalid authentication token" }, status: :unauthorized
          nil
        end
      end

      def authenticate_oauth(token)
        access_token = Doorkeeper::AccessToken.by_token(token)
        return false unless access_token&.accessible?

        user = Collavre::User.find_by(id: access_token.resource_owner_id)
        return false unless user

        @current_api_user = user
        true
      end

      def extract_bearer_token
        auth_header = request.headers["Authorization"]
        return nil unless auth_header&.start_with?("Bearer ")

        auth_header.sub("Bearer ", "")
      end

      def current_api_user
        @current_api_user
      end
    end
  end
end

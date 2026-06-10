# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class BaseController < ActionController::API
        before_action :authenticate!

        private

        def authenticate!
          token = extract_bearer_token
          if token.blank?
            render json: { error: "Missing authentication token" }, status: :unauthorized
            return
          end

          access_token = Doorkeeper::AccessToken.by_token(token)
          unless access_token&.accessible?
            render json: { error: "Invalid authentication token" }, status: :unauthorized
            return
          end

          user = Collavre::User.find_by(id: access_token.resource_owner_id)
          unless user
            render json: { error: "User not found" }, status: :unauthorized
            return
          end

          Collavre::Current.user = user
        end

        def extract_bearer_token
          auth_header = request.headers["Authorization"]
          return nil unless auth_header&.start_with?("Bearer ")

          auth_header.sub("Bearer ", "")
        end

        def current_user
          Collavre::Current.user
        end
      end
    end
  end
end

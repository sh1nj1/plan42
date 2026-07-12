# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class BaseController < ActionController::API
        include Collavre::Api::Authenticatable

        before_action :authenticate!

        private

        def authenticate!
          token = extract_bearer_token
          if token.blank?
            render json: { error: "Missing authentication token" }, status: :unauthorized
            return
          end

          unless find_user_by_bearer_token(token)
            render json: { error: "Invalid authentication token" }, status: :unauthorized
          end
        end
      end
    end
  end
end

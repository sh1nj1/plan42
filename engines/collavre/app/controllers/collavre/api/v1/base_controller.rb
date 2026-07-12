# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class BaseController < ActionController::API
        include Collavre::Api::Authenticatable

        before_action :authenticate!

        rescue_from Collavre::ApiError do |e|
          render json: { error: e.message }, status: e.status
        end

        private

        def authenticate!
          token = extract_bearer_token
          raise Collavre::ApiError.new("Missing authentication token", status: :unauthorized) if token.blank?

          unless find_user_by_bearer_token(token)
            raise Collavre::ApiError.new("Invalid authentication token", status: :unauthorized)
          end
        end
      end
    end
  end
end

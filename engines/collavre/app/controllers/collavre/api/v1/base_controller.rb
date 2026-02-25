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
            render json: { error: { message: "Missing authentication token", type: "invalid_request_error",
                                    code: "missing_token" } },
                   status: :unauthorized
            return
          end

          # Try OAuth (Doorkeeper) first, then fall back to API key
          if authenticate_oauth(token) || authenticate_api_key(token)
            return
          end

          render json: { error: { message: "Invalid authentication token", type: "invalid_request_error",
                                  code: "invalid_token" } },
                 status: :unauthorized
        end

        def authenticate_oauth(token)
          access_token = Doorkeeper::AccessToken.by_token(token)
          return false unless access_token&.accessible?

          user = Collavre::User.find_by(id: access_token.resource_owner_id)
          return false unless user

          Current.user = user
          true
        end

        def authenticate_api_key(token)
          api_key = Collavre::ApiKey.find_by_token(token)
          return false unless api_key

          api_key.touch_last_used!
          Current.user = api_key.user
          true
        end

        def extract_bearer_token
          auth_header = request.headers["Authorization"]
          return nil unless auth_header&.start_with?("Bearer ")

          auth_header.sub("Bearer ", "")
        end

        def collavre_creative
          @collavre_creative ||= begin
            creative_id = request.headers["X-Collavre-Creative"]
            return nil if creative_id.blank?

            creative = Collavre::Creative.find_by(id: creative_id)&.effective_origin
            return nil unless creative&.has_permission?(Current.user, :member)

            creative
          end
        end

        def collavre_topic
          @collavre_topic ||= begin
            topic_id = request.headers["X-Collavre-Topic"]
            return nil if topic_id.blank?
            return nil unless collavre_creative

            collavre_creative.topics.find_by(id: topic_id)
          end
        end
      end
    end
  end
end

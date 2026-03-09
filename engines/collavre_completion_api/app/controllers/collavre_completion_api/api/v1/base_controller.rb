# frozen_string_literal: true

module CollavreCompletionApi
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

          unless authenticate_oauth(token)
            render json: { error: { message: "Invalid authentication token", type: "invalid_request_error",
                                    code: "invalid_token" } },
                   status: :unauthorized
            nil
          end
        end

        def authenticate_oauth(token)
          access_token = Doorkeeper::AccessToken.by_token(token)
          return false unless access_token&.accessible?

          user = Collavre::User.find_by(id: access_token.resource_owner_id)
          return false unless user

          Collavre::Current.user = user
          true
        end

        def extract_bearer_token
          auth_header = request.headers["Authorization"]
          return nil unless auth_header&.start_with?("Bearer ")

          auth_header.sub("Bearer ", "")
        end

        def current_user
          Collavre::Current.user
        end

        # Model ID format: email username (before @)
        # e.g., "devbot" for devbot@collavre.local
        # Falls back to "collavre/{id}" if email is blank
        def agent_model_id(agent)
          if agent.email.present?
            agent.email.split("@").first
          else
            "collavre/#{agent.id}"
          end
        end

        # Resolve agent from model parameter (email username or legacy collavre/id format)
        def resolve_agent_by_model(model_param)
          return nil if model_param.blank?

          agent = if model_param.start_with?("collavre/")
            # Legacy format: collavre/{id}
            Collavre::User.find_by(id: model_param.sub("collavre/", ""))
          else
            # Email username format
            Collavre::User.where("email LIKE ?", "#{model_param}@%").first
          end

          return nil unless agent&.ai_user?
          return nil unless agent.created_by_id == current_user.id || agent.searchable?

          agent
        end

        def collavre_creative
          @collavre_creative ||= begin
            creative_id = request.headers["X-Collavre-Creative"]
            return nil if creative_id.blank?

            creative = Collavre::Creative.find_by(id: creative_id)&.effective_origin
            return nil unless creative&.has_permission?(current_user, :member)

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

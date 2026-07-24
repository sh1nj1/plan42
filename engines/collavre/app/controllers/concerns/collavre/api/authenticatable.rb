# frozen_string_literal: true

module Collavre
  module Api
    module Authenticatable
      extend ActiveSupport::Concern

      private

      def extract_bearer_token
        auth_header = request.headers["Authorization"]
        return nil unless auth_header&.start_with?("Bearer ")

        auth_header.sub("Bearer ", "")
      end

      # Resolves the bearer token to a user via Doorkeeper, sets
      # Collavre::Current.user, and returns the user. Returns nil (without
      # rendering) when the token is blank/invalid/inaccessible or the user
      # is missing — callers own the error response, because the two API
      # engines render different error envelopes.
      def find_user_by_bearer_token(token)
        return nil if token.blank?

        access_token = Doorkeeper::AccessToken.by_token(token)
        return nil unless access_token&.accessible?

        user = Collavre::User.find_by(id: access_token.resource_owner_id)
        return nil unless user

        Collavre::Current.user = user
        user
      end

      def current_user
        Collavre::Current.user
      end
    end
  end
end

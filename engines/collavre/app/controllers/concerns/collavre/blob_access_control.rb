# frozen_string_literal: true

module Collavre
  # Per-request authorization for controllers that serve blob bytes outside the
  # Collavre ApplicationController stack (/public-assets and the ActiveStorage
  # blob/representation endpoints). The viewer comes from the session cookie or
  # an OAuth bearer token, so browsers and agents/CLI share one rule set
  # (Collavre::BlobAccess). Unauthorized requests get 404, not 403, so the
  # response does not confirm that the blob exists.
  module BlobAccessControl
    extend ActiveSupport::Concern

    PRIVATE_CACHE_CONTROL = "private, no-store"

    private

    def blob_viewer
      return @blob_viewer if defined?(@blob_viewer)

      @blob_viewer = session_blob_viewer || bearer_blob_viewer
    end

    def blob_readable?(blob, user: blob_viewer)
      Collavre::BlobAccess.new(blob, user: user).readable?
    end

    def mark_private_blob_response!
      response.headers["Cache-Control"] = PRIVATE_CACHE_CONTROL
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
    end

    def session_blob_viewer
      session_id = cookies.signed[:session_id]
      return unless session_id

      session = Collavre::Session.find_by(id: session_id)
      return if session.nil? || session.expired?

      session.user
    end

    def bearer_blob_viewer
      token_string = Doorkeeper::OAuth::Token.from_request(
        request, *Doorkeeper.configuration.access_token_methods
      )
      return if token_string.blank?

      token = Doorkeeper::AccessToken.by_token(token_string)
      Collavre.user_class.find_by(id: token.resource_owner_id) if token&.accessible?
    end
  end
end

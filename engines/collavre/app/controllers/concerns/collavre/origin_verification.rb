# frozen_string_literal: true

module Collavre
  # Rejects requests that reach the Rails origin without CloudFront's
  # X-Origin-Secret header, so the CDN cannot be bypassed. Shared by the host
  # ApplicationController and the controllers that do not inherit from it
  # (/public-assets and the ActiveStorage blob endpoints).
  module OriginVerification
    extend ActiveSupport::Concern

    private

    def verify_cloudfront_origin!
      return if skip_cloudfront_verification?

      unless request.headers["X-Origin-Secret"] == Collavre::IntegrationSettings.fetch(:origin_shared_secret)
        head :forbidden
      end
    end

    def skip_cloudfront_verification?
      return false if request.headers["X-Origin-Secret"].present?
      return true if Collavre::IntegrationSettings.fetch(:origin_shared_secret).blank?

      # health checks, internal callbacks, etc.
      request.path.start_with?("/up") || request.path.start_with?("/health")
    end
  end
end

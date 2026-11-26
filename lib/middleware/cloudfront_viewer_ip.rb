# frozen_string_literal: true

require "ipaddr"

module Collavre
  class CloudfrontViewerIp
    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      viewer_ip = trusted_viewer_ip(request)
      request.remote_ip = viewer_ip if viewer_ip
      @app.call(env)
    end

    private

    def trusted_viewer_ip(request)
      return unless ENV["TRUST_CLOUDFRONT_VIEWER_ADDRESS"] == "true"

      viewer_address = request.headers["CloudFront-Viewer-Address"]
      origin_secret = request.headers["X-Origin-Secret"]
      return if viewer_address.blank? || origin_secret.blank?

      expected_secret = IntegrationSettings.fetch(:origin_shared_secret)
      return unless expected_secret && ActiveSupport::SecurityUtils.secure_compare(origin_secret, expected_secret)

      address, separator, port = viewer_address.rpartition(":")
      return unless separator.present? && port.match?(/\A[0-9]{1,5}\z/) && port.to_i.between?(1, 65_535)
      return unless address.match?(/\A(?:[0-9a-f:.]+|\[[0-9a-f:.]+\])\z/i)

      IPAddr.new(address).native.to_s
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
end

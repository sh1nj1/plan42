# frozen_string_literal: true

require "openssl"
require "active_support/security_utils"

module Collavre
  # Shared HMAC signature verification for inbound provider webhooks.
  #
  # Each provider signs its payload differently, so `verify` dispatches on a
  # `scheme` symbol and keeps every provider's exact signing scheme intact:
  #
  #   * :github — header value is `sha256=<hexdigest>` (or legacy `sha1=`);
  #     the digest is HMAC(secret, raw_body) and the compared string carries the
  #     `<algo>=` prefix (X-Hub-Signature-256 / X-Hub-Signature).
  #   * :linear — header value is the bare HMAC-SHA256 hexdigest of raw_body
  #     (Linear-Signature).
  #   * :slack — header value is `v0=<HMAC-SHA256(signing_secret, basestring)>`
  #     where basestring is `v0:{timestamp}:{raw_body}` (X-Slack-Signature).
  #
  # SECURITY: this helper only proves the sender holds the signing secret. It is
  # deliberately side-effect free and performs no tenant/team routing. Callers
  # must resolve the tenant/team from the payload only to look up the signing
  # secret, verify the signature FIRST, and never act on payload-derived routing
  # before a successful verification. All comparisons are constant-time via
  # ActiveSupport::SecurityUtils.secure_compare.
  module WebhookSignature
    module_function

    # @param scheme [Symbol] :github, :linear, or :slack
    # @param secret [String, nil] the provider's signing secret
    # @param body [String] the raw request body exactly as received
    # @param signature [String, nil] the provider signature header value
    # @param timestamp [String, nil] Slack request timestamp (Slack only)
    # @return [Boolean] true iff the signature is valid
    def verify(scheme:, secret:, body:, signature:, timestamp: nil)
      return false if secret.blank? || signature.blank?

      case scheme
      when :github
        verify_github(secret, body, signature)
      when :linear
        verify_linear(secret, body, signature)
      when :slack
        verify_slack(secret, body, signature, timestamp)
      else
        false
      end
    end

    # GitHub: signature header is `<algo>=<hexdigest>`; the compared value keeps
    # the algorithm prefix. Supports sha256 (current) and legacy sha1.
    def verify_github(secret, body, signature)
      algorithm =
        if signature.start_with?("sha256=")
          "sha256"
        elsif signature.start_with?("sha1=")
          "sha1"
        end
      return false if algorithm.blank?

      digest = OpenSSL::HMAC.hexdigest(algorithm.upcase, secret, body)
      secure_compare("#{algorithm}=#{digest}", signature)
    end
    private_class_method :verify_github

    # Linear: signature header is the bare HMAC-SHA256 hexdigest of the body.
    def verify_linear(secret, body, signature)
      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      secure_compare(expected, signature)
    end
    private_class_method :verify_linear

    # Slack: signs `v0:{timestamp}:{body}` and prefixes the digest with `v0=`.
    # The replay-window freshness check on the timestamp stays in the controller.
    def verify_slack(secret, body, signature, timestamp)
      return false if timestamp.blank?

      base = "v0:#{timestamp}:#{body}"
      expected = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, base)}"
      secure_compare(expected, signature)
    end
    private_class_method :verify_slack

    def secure_compare(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end
    private_class_method :secure_compare
  end
end

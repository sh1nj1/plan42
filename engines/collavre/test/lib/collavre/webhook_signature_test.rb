# frozen_string_literal: true

require "test_helper"

module Collavre
  # WebhookSignature verifies each provider's HMAC scheme exactly. These tests
  # pin the wire format (GitHub's `sha256=` prefix, Linear's bare digest, Slack's
  # `v0:{ts}:{body}` basestring) and the blank-input / wrong-secret rejections.
  class WebhookSignatureTest < ActiveSupport::TestCase
    SECRET = "s3cr3t"
    BODY = '{"hello":"world"}'

    # --- shared guards ---------------------------------------------------------

    test "returns false when the secret is blank" do
      refute WebhookSignature.verify(
        scheme: :github, secret: "", body: BODY, signature: "sha256=abc"
      )
    end

    test "returns false when the signature is blank" do
      refute WebhookSignature.verify(
        scheme: :linear, secret: SECRET, body: BODY, signature: nil
      )
    end

    test "returns false for an unknown scheme" do
      refute WebhookSignature.verify(
        scheme: :bogus, secret: SECRET, body: BODY, signature: "x"
      )
    end

    # --- GitHub ----------------------------------------------------------------

    test "github accepts a valid sha256 signature" do
      sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, BODY)}"
      assert WebhookSignature.verify(
        scheme: :github, secret: SECRET, body: BODY, signature: sig
      )
    end

    test "github accepts a valid legacy sha1 signature" do
      sig = "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', SECRET, BODY)}"
      assert WebhookSignature.verify(
        scheme: :github, secret: SECRET, body: BODY, signature: sig
      )
    end

    test "github rejects a signature with no algorithm prefix" do
      digest = OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)
      refute WebhookSignature.verify(
        scheme: :github, secret: SECRET, body: BODY, signature: digest
      )
    end

    test "github rejects a wrong secret" do
      sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'other', BODY)}"
      refute WebhookSignature.verify(
        scheme: :github, secret: SECRET, body: BODY, signature: sig
      )
    end

    # --- Linear ----------------------------------------------------------------

    test "linear accepts a valid bare hexdigest signature" do
      sig = OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)
      assert WebhookSignature.verify(
        scheme: :linear, secret: SECRET, body: BODY, signature: sig
      )
    end

    test "linear rejects a tampered body" do
      sig = OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)
      refute WebhookSignature.verify(
        scheme: :linear, secret: SECRET, body: "#{BODY} ", signature: sig
      )
    end

    # --- Slack -----------------------------------------------------------------

    test "slack accepts a valid v0 signature over the timestamped basestring" do
      timestamp = "1600000000"
      base = "v0:#{timestamp}:#{BODY}"
      sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, base)}"
      assert WebhookSignature.verify(
        scheme: :slack, secret: SECRET, body: BODY, signature: sig, timestamp: timestamp
      )
    end

    test "slack rejects when the timestamp is missing from the basestring" do
      timestamp = "1600000000"
      base = "v0:#{timestamp}:#{BODY}"
      sig = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, base)}"
      refute WebhookSignature.verify(
        scheme: :slack, secret: SECRET, body: BODY, signature: sig, timestamp: nil
      )
    end

    test "slack rejects a signature computed without the v0 prefix scheme" do
      timestamp = "1600000000"
      sig = OpenSSL::HMAC.hexdigest("SHA256", SECRET, BODY)
      refute WebhookSignature.verify(
        scheme: :slack, secret: SECRET, body: BODY, signature: sig, timestamp: timestamp
      )
    end
  end
end

require "test_helper"

module Collavre
  class LoopbackRequestTest < ActiveSupport::TestCase
    class RequestHarness
      include LoopbackRequest
      attr_accessor :request, :status

      def initialize(address)
        @request = Struct.new(:remote_addr).new(address)
      end

      def head(status)
        @status = status
      end

      public :request_from_loopback?, :require_loopback!, :require_desktop_mode!
    end

    test "accepts native and mapped loopback socket peers" do
      %w[127.0.0.1 127.4.5.6 ::1 ::ffff:127.0.0.1].each do |address|
        harness = RequestHarness.new(address)
        assert harness.request_from_loopback?, address
        assert harness.require_loopback!, address
        assert_nil harness.status
      end
    end

    test "rejects remote and malformed socket peers" do
      [ "10.0.0.25", "192.168.1.2", "::ffff:192.168.1.2", "2001:db8::1", "invalid", "", nil ].each do |address|
        harness = RequestHarness.new(address)
        assert_not harness.request_from_loopback?, address.inspect
        assert_not harness.require_loopback!, address.inspect
        assert_equal :forbidden, harness.status
      end
    end

    test "desktop mode requires the exact true value" do
      previous = Rails.application.config.x.desktop_proxy_setup
      [ false, nil, "true", true ].each do |value|
        Rails.application.config.x.desktop_proxy_setup = value
        harness = RequestHarness.new("127.0.0.1")
        assert_equal value == true, harness.require_desktop_mode!
        value == true ? assert_nil(harness.status) : assert_equal(:not_found, harness.status)
      end
    ensure
      Rails.application.config.x.desktop_proxy_setup = previous
    end
  end
end

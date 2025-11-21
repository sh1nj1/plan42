require "action_controller"

module OmniAuth
  module RailsCsrfProtection
    # Provides a callable method that verifies Cross-Site Request Forgery
    # protection token. This implementation mirrors the omniauth-rails_csrf_protection
    # behavior without relying on the deprecated ActiveSupport::Configurable module.
    class TokenVerifier
      class << self
        def config
          ActionController::Base.config
        end
      end

      include ActionController::RequestForgeryProtection

      def self.configure_from_action_controller!
        config.to_h.keys.each do |configuration_name|
          remove_method(configuration_name) if method_defined?(configuration_name)

          define_method(configuration_name) do
            config[configuration_name]
          end
        end
      end

      configure_from_action_controller!

      def call(env)
        dup._call(env)
      end

      def _call(env)
        @request = ActionDispatch::Request.new(env.dup)

        raise ActionController::InvalidAuthenticityToken unless verified_request?
      end

      private

        attr_reader :request
        delegate :params, :session, to: :request
    end
  end
end

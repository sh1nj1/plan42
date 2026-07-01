# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module CollavreLinear
  # Handles Linear OAuth 2.0 flows:
  #   - authorize_url  : build the URL that sends the user to Linear's OAuth screen
  #   - exchange       : trade an authorization code for tokens (authorization_code grant)
  #   - refresh        : silently refresh tokens when they are expiring soon (refresh_token grant)
  #
  # Secret resolution order: DB Resolver > ENV > Rails.application.credentials
  # (consistent with CollavreLinear::Client and other engine services in this codebase)
  class OAuthTokenService
    LINEAR_AUTH_ENDPOINT  = "https://linear.app/oauth/authorize"
    LINEAR_TOKEN_ENDPOINT = "https://api.linear.app/oauth/token"
    # NOTE: `admin` is intentionally NOT requested. Linear rejects it for app
    # actors ("App users can't request admin scopes"), which is how we authorize
    # (actor: "app"). `admin` is only needed to auto-create webhooks via the API;
    # without it WebhookProvisioner.ensure_for cannot provision, so inbound sync
    # is wired up MANUALLY instead — the integration modal shows a one-time
    # webhook setup guide (URL + signing secret + events) after linking.
    OAUTH_SCOPES          = "read,write,issues:create,comments:create"

    class Error < StandardError; end

    class << self
      # Build the URL that redirects the user to Linear for authorization.
      #
      # @param state [String] CSRF token / opaque value passed through the OAuth flow
      # @param creative_id [Integer] stored in session before redirect; not sent to Linear
      # @return [String] full URL including query params
      def authorize_url(state:, creative_id:)
        params = {
          response_type: "code",
          client_id:     client_id,
          redirect_uri:  redirect_uri,
          scope:         OAUTH_SCOPES,
          actor:         "app",
          state:         state
        }
        "#{LINEAR_AUTH_ENDPOINT}?#{URI.encode_www_form(params)}"
      end

      # Exchange an authorization code for access + refresh tokens.
      #
      # @param code [String] authorization code from Linear callback
      # @return [Hash] with symbolized keys :access_token, :refresh_token, :expires_in
      def exchange(code)
        params = {
          grant_type:    "authorization_code",
          code:          code,
          redirect_uri:  redirect_uri,
          client_id:     client_id,
          client_secret: client_secret
        }
        post_token!(params)
      end

      # Refresh tokens if the account is expiring soon.
      # Persists new token values to the account and returns it.
      # No-ops (returns account unchanged) if not expiring soon.
      #
      # @param account [CollavreLinear::Account]
      # @return [CollavreLinear::Account]
      def refresh(account)
        return account unless account.token_expiring_soon?

        params = {
          grant_type:    "refresh_token",
          refresh_token: account.refresh_token,
          client_id:     client_id,
          client_secret: client_secret
        }

        tokens = post_token!(params)

        attrs = {
          access_token:     tokens[:access_token],
          token_expires_at: Time.current + tokens[:expires_in].to_i.seconds
        }
        attrs[:refresh_token] = tokens[:refresh_token] if tokens[:refresh_token].present?
        account.update!(attrs)
        account
      end

      private

      # Post form-encoded body to the Linear token endpoint.
      # @return [Hash] symbolized response body
      def post_token!(params)
        uri  = URI.parse(LINEAR_TOKEN_ENDPOINT)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Post.new(uri.path)
        request["Content-Type"]  = "application/x-www-form-urlencoded"
        request["Accept"]        = "application/json"
        request.body             = URI.encode_www_form(params)

        response = http.request(request)

        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise Error, "Linear returned non-JSON token response (HTTP #{response.code})"
        end

        unless response.is_a?(Net::HTTPSuccess)
          error_detail = parsed["error"] || parsed["error_description"] || "(no error field)"
          raise Error, "Linear token request failed (HTTP #{response.code}): #{error_detail}"
        end

        parsed.transform_keys(&:to_sym)
      end

      # Secret resolution: DB Resolver > ENV > Rails credentials
      def client_id
        resolve_secret(:linear_client_id) ||
          Rails.application.credentials.dig(:linear, :client_id)
      end

      def client_secret
        resolve_secret(:linear_client_secret) ||
          Rails.application.credentials.dig(:linear, :client_secret)
      end

      def redirect_uri
        resolve_secret(:linear_oauth_redirect_uri) ||
          Rails.application.credentials.dig(:linear, :oauth_redirect_uri)
      end

      def resolve_secret(key)
        return unless defined?(Collavre::IntegrationSettings::Resolver)

        Collavre::IntegrationSettings::Resolver.get(key)
      rescue Collavre::IntegrationSettings::Resolver::UnknownKeyError
        ENV[key.to_s.upcase]
      rescue ActiveRecord::StatementInvalid,
             ActiveRecord::NoDatabaseError,
             ActiveRecord::ConnectionNotEstablished
        ENV[key.to_s.upcase]
      end
    end
  end
end

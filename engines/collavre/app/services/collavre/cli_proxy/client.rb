# frozen_string_literal: true

module Collavre
  module CliProxy
    class Client
      class Error < StandardError
        attr_reader :status, :code, :details

        def initialize(message, status: nil, code: nil, details: nil)
          super(message)
          @status = status
          @code = code
          @details = details
        end
      end

      def initialize(gateway:, workspace: nil, user_key: nil, http_client: nil)
        @gateway = gateway
        @workspace = workspace
        @user_key = user_key
        @http_client = http_client || default_http_client
      end

      def engines
        request(:get, "/v1/auth/engines")
      end

      def engine_status(engine)
        request(:get, "/v1/auth/#{segment(engine)}/status")
      end

      def create_auth_session(engine, flow:, provisioning_url:)
        request(
          :post,
          "/v1/auth/#{segment(engine)}/sessions",
          body: { flow: flow, provisioning_url: provisioning_url }.compact
        )
      end

      def auth_session(engine, session_id)
        request(:get, "/v1/auth/#{segment(engine)}/sessions/#{segment(session_id)}")
      end

      def submit_auth_session(engine, session_id, value)
        request(
          :post,
          "/v1/auth/#{segment(engine)}/sessions/#{segment(session_id)}",
          body: { value: value }
        )
      end

      def cancel_auth_session(engine, session_id)
        request(:delete, "/v1/auth/#{segment(engine)}/sessions/#{segment(session_id)}")
      end

      def provision_status
        request(:get, "/v1/provision")
      end

      # Registers the workspace manifest URL and applies it, without a login.
      # The login-carried provisioning_url does the same thing as a side effect
      # of authenticating; this route is how an already-authenticated workspace
      # gets (re)provisioned.
      def provision_register_manifest(url)
        request(:post, "/v1/provision/manifest", body: { url: url })
      end

      def provision_sync
        request(:post, "/v1/provision/sync")
      end

      def provision_approve(type, name)
        request(:post, "/v1/provision/items/#{segment(type)}/#{segment(name)}/approve")
      end

      def provision_delete(type, name)
        request(:delete, "/v1/provision/items/#{segment(type)}/#{segment(name)}")
      end

      private

      def default_http_client
        requires_endpoint_policy = !@gateway.owner.system_admin? &&
          !@gateway.desktop_loopback?
        policy = EndpointPolicy.new if requires_endpoint_policy
        Collavre::HttpClient.new(open_timeout: 5, read_timeout: 35, endpoint_policy: policy)
      end

      def request(method, path, body: nil)
        headers = {
          "Authorization" => "Bearer #{@gateway.admin_key}",
          "Accept" => "application/json"
        }
        headers["X-CLI-Proxy-User-Key"] = @user_key if @user_key.present?
        headers.merge!(Identity.headers(gateway: @gateway, workspace: @workspace, method: method, path: path)) if @workspace
        headers["Content-Type"] = "application/json" if body

        response = if method == :delete
          @http_client.delete(@gateway.proxy_path(path), headers: headers)
        elsif method == :get
          @http_client.get(@gateway.proxy_path(path), headers: headers)
        else
          @http_client.public_send(
            method,
            @gateway.proxy_path(path),
            body: body&.to_json,
            headers: headers
          )
        end
        parsed = parse_body(response)
        return parsed || {} if response.success?

        error = parsed.is_a?(Hash) ? (parsed["error"] || parsed) : {}
        raise Error.new(
          error["message"].presence || response.message,
          status: response.code,
          code: error["code"],
          details: parsed
        )
      rescue Collavre::HttpClient::ConnectionError => e
        raise Error.new(e.message, code: "proxy_unreachable")
      rescue EndpointPolicy::UnsafeEndpoint
        raise Error.new(I18n.t("collavre.agent_gateways.unsafe_endpoint"), code: "unsafe_proxy_endpoint")
      end

      # A failure may answer with a non-JSON body: the proxy itself answers JSON
      # throughout, but anything in front of it (a reverse proxy, a gateway
      # error page) does not. Keep the HTTP status in that case so a caller can
      # branch on it — a 404 is how an endpoint this proxy version lacks reports
      # itself — instead of collapsing it into a status-less parse error.
      def parse_body(response)
        response.json
      rescue JSON::ParserError => e
        raise Error.new("Invalid JSON from CLI proxy", details: e.message) if response.success?

        nil
      end

      def segment(value)
        value = value.to_s
        raise ArgumentError, "Invalid path segment" unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)

        value
      end
    end
  end
end

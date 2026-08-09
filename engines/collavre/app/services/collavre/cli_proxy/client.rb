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
        @http_client = http_client || Collavre::HttpClient.new(open_timeout: 5, read_timeout: 35)
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
        parsed = response.json
        return parsed || {} if response.success?

        error = parsed.is_a?(Hash) ? (parsed["error"] || parsed) : {}
        raise Error.new(
          error["message"].presence || response.message,
          status: response.code,
          code: error["code"],
          details: parsed
        )
      rescue JSON::ParserError => e
        raise Error.new("Invalid JSON from CLI proxy", details: e.message)
      rescue Collavre::HttpClient::ConnectionError => e
        raise Error.new(e.message, code: "proxy_unreachable")
      end

      def segment(value)
        value = value.to_s
        raise ArgumentError, "Invalid path segment" unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)

        value
      end
    end
  end
end

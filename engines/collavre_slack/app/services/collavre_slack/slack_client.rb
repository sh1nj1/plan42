module CollavreSlack
  class SlackClient
    BASE_URL = "https://slack.com/api".freeze

    def initialize(access_token: nil)
      @access_token = access_token
    end

    def oauth_authorize_url(state: nil)
      query = {
        client_id: client_id,
        scope: default_scopes,
        redirect_uri: redirect_uri,
        state: state
      }.compact

      "https://slack.com/oauth/v2/authorize?#{query.to_query}"
    end

    def oauth_access(code:, redirect_uri:)
      response = connection.post("oauth.v2.access", {
        client_id: client_id,
        client_secret: client_secret,
        code: code,
        redirect_uri: redirect_uri
      })

      parse_response(response)
    end

    def list_channels
      get("conversations.list", limit: 1000, types: "public_channel,private_channel")
    end

    def list_messages(channel:, oldest: nil)
      params = { channel: channel, limit: 200 }.compact
      params[:oldest] = oldest if oldest.present?
      get("conversations.history", params)
    end

    def post_message(channel:, text:)
      post("chat.postMessage", { channel: channel, text: text })
    end

    def get_user_info(user_id:)
      get("users.info", user: user_id)
    end

    def add_reaction(channel:, timestamp:, name:)
      post("reactions.add", { channel: channel, timestamp: timestamp, name: name })
    end

    def remove_reaction(channel:, timestamp:, name:)
      post("reactions.remove", { channel: channel, timestamp: timestamp, name: name })
    end

    def redirect_uri
      CollavreSlack.config.redirect_uri
    end

    private

    attr_reader :access_token

    def client_id
      CollavreSlack.config.client_id
    end

    def client_secret
      CollavreSlack.config.client_secret
    end

    def default_scopes
      CollavreSlack.config.scopes
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |builder|
        builder.request :url_encoded
        builder.request :retry, max: 3, interval: 0.2, backoff_factor: 2
        builder.response :raise_error
      end
    end

    def get(path, params = {})
      request_with_handling do
        connection.get(path) do |request|
          request.headers["Authorization"] = "Bearer #{access_token}" if access_token.present?
          request.params.update(params)
        end
      end
    end

    def post(path, payload = {})
      request_with_handling do
        connection.post(path) do |request|
          request.headers["Authorization"] = "Bearer #{access_token}" if access_token.present?
          request.headers["Content-Type"] = "application/json; charset=utf-8"
          request.body = payload.to_json
        end
      end
    end

    def parse_response(response)
      parsed = JSON.parse(response.body, symbolize_names: true)
      parsed.merge(status: response.status, headers: response.headers)
    rescue JSON::ParserError
      { ok: false, error: "invalid_json", status: response.status, headers: response.headers }
    end

    def request_with_handling
      error_response = {}
      response = yield
      parse_response(response)
    rescue Faraday::ClientError => e
      error_response = e.response || {}
      body = error_response[:body].to_s
      parsed = JSON.parse(body, symbolize_names: true)
      parsed.merge(status: error_response[:status], headers: error_response[:headers])
    rescue JSON::ParserError
      { ok: false, error: "http_error", status: error_response[:status], headers: error_response[:headers] }
    end
  end
end

class McpOauthMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)

    if request.path.start_with?("/mcp")
      if valid_oauth_token?(request)
        status, headers, body = @app.call(env)

        if request.path == "/mcp/sse"
          puts "McpOauthMiddleware: Modifying headers for #{request.path}"
          puts "Original headers: #{headers.inspect}"
          headers["Cache-Control"] = "no-cache"
          headers["X-Accel-Buffering"] = "no"
          headers.delete("ETag")
          puts "Modified headers: #{headers.inspect}"
        else
          puts "McpOauthMiddleware: Skipping header modification for #{request.path}"
        end

        [ status, headers, body ]
      else
        [ 401, { "Content-Type" => "application/json", "WWW-Authenticate" => 'Bearer realm="Doorkeeper"' }, [ { error: "Unauthorized" }.to_json ] ]
      end
    else
      @app.call(env)
    end
  end

  private

  def valid_oauth_token?(request)
    token_string = Doorkeeper::OAuth::Token.from_request(request, *Doorkeeper.configuration.access_token_methods)
    return false if token_string.blank?

    token = Doorkeeper::AccessToken.by_token(token_string)
    token&.accessible?
  end
end

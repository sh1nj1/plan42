module CollavreSlack
  class Configuration
    attr_accessor :client_id, :client_secret, :signing_secret, :redirect_uri, :scopes

    def initialize
      @client_id = ENV.fetch("SLACK_CLIENT_ID", "")
      @client_secret = ENV.fetch("SLACK_CLIENT_SECRET", "")
      @signing_secret = ENV.fetch("SLACK_SIGNING_SECRET", "")
      @redirect_uri = ENV.fetch("SLACK_REDIRECT_URI", "")
      @scopes = ENV.fetch("SLACK_SCOPES", "chat:write,channels:read,channels:history,groups:read,im:read,mpim:read,users:read,users:read.email,reactions:read,reactions:write")
    end
  end
end

require "collavre_slack/version"
require "collavre_slack/configuration"
require "collavre_slack/engine"

module CollavreSlack
  def self.config
    @config ||= Configuration.new
  end

  def self.configure
    yield(config)
  end
end

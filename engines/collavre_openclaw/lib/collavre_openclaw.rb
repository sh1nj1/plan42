require "collavre_openclaw/version"
require "collavre_openclaw/configuration"
require "collavre_openclaw/engine"

module CollavreOpenclaw
  def self.config
    @config ||= Configuration.new
  end

  def self.configure
    yield(config)
  end
end

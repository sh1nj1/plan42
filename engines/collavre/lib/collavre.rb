require "collavre/version"
require "collavre/configuration"
require "collavre/engine"
require "collavre/user_extensions"
require "navigation/registry"

module Collavre
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def user_class
      configuration.user_class
    end

    def current_user
      configuration.current_user_method.call
    end
  end
end

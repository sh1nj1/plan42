# Ruby's URI parser is ASCII-only, so it rejects an internationalized hostname a
# browser converts and navigates happily. NavigationHelper needs
# Addressable::URI#normalized_host to compare such a help URL against our own
# Host header, and its fallback rescues StandardError — so a missing constant
# would not raise here but degrade silently, one deployment at a time. Required
# from the engine, and declared in the gemspec, so it holds when Collavre is
# installed as a gem rather than through this repository's Gemfile.
require "addressable/uri"

require "collavre/version"
require "collavre/configuration"
require "collavre/engine"
require "collavre/user_extensions"
require "collavre/integration_registry"
require "collavre/feature_card_registry"
require "collavre/integration_settings"
require "collavre/aws_credentials"
require "collavre/ses_settings_interceptor"
require "collavre/view_extensions"
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

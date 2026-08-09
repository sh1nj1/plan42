# frozen_string_literal: true

require "active_support/logger_silence"

module Collavre
  # Prevents capability-bearing request paths from reaching any Rails log level.
  # Logger::UNKNOWN + 1 is intentional: the built-in SilenceRequest defaults to
  # ERROR, which still permits exception logs containing the original path.
  class SensitiveRequestSilencer
    SILENCE_LEVEL = ::Logger::UNKNOWN + 1

    def initialize(app, path:)
      @app = app
      @path = path
    end

    def call(env)
      return @app.call(env) unless @path === env["PATH_INFO"]

      Rails.logger.silence(SILENCE_LEVEL) { @app.call(env) }
    end
  end
end

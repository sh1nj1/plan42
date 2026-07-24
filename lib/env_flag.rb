# frozen_string_literal: true

# Boolean reading for ENV flags that are consumed before Rails boots — notably
# `config/puma.rb`, where ActiveModel's type cast is not available yet.
#
# Only affirmative spellings enable a flag. Everything else, including the empty
# string a deploy template renders for an unset variable, reads as disabled.
module EnvFlag
  TRUTHY = %w[1 t true y yes on].freeze

  # `env` is injectable so the reading can be tested without mutating ENV.
  def self.enabled?(name, env: ENV, default: false)
    raw = env[name]
    return default if raw.nil?

    TRUTHY.include?(raw.to_s.strip.downcase)
  end
end

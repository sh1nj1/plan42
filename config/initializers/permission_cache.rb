# Permission caching configuration
Rails.application.configure do
  # Configure permission cache expiry time
  # Can be overridden with PERMISSION_CACHE_EXPIRES_IN environment variable
  # Default: 7 days
  config.permission_cache_expires_in = ENV.fetch("PERMISSION_CACHE_EXPIRES_IN", "7.days").then do |value|
    case value
    when /\A\d+\.days?\z/
      eval(value)
    when /\A\d+\.hours?\z/
      eval(value)
    when /\A\d+\.minutes?\z/
      eval(value)
    when /\A\d+\z/
      value.to_i.seconds
    else
      7.days
    end
  end
end

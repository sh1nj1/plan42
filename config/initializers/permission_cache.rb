# Permission caching configuration
Rails.application.configure do
  # Configure permission cache expiry time
  # Can be overridden with PERMISSION_CACHE_EXPIRES_IN environment variable
  # Default: 7 days
  # Supported formats: "7.days", "12.hours", "30.minutes", "3600" (seconds)
  config.permission_cache_expires_in = ENV.fetch("PERMISSION_CACHE_EXPIRES_IN", "7.days").then do |value|
    case value
    when /\A(\d+)\.days?\z/
      $1.to_i.days
    when /\A(\d+)\.hours?\z/
      $1.to_i.hours
    when /\A(\d+)\.minutes?\z/
      $1.to_i.minutes
    when /\A(\d+)\z/
      $1.to_i.seconds
    else
      Rails.logger.warn "Invalid PERMISSION_CACHE_EXPIRES_IN format: #{value.inspect}. Using default 7 days."
      7.days
    end
  end
end

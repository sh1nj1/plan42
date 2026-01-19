module DynamicRateLimiting
  extend ActiveSupport::Concern

  class RateLimitExceeded < StandardError; end

  included do
    rescue_from RateLimitExceeded, with: :rate_limit_exceeded_response
  end

  private

  # Check rate limit using Rails cache
  # @param key [String] Unique identifier for the rate limit bucket (e.g., "password_reset:#{ip}")
  # @param limit [Integer] Maximum number of requests allowed
  # @param period [ActiveSupport::Duration] Time period for the limit
  # @return [Boolean] true if within limit, raises RateLimitExceeded if exceeded
  def check_rate_limit!(key:, limit:, period:)
    cache_key = "rate_limit:#{key}"
    current_count = Rails.cache.read(cache_key).to_i

    if current_count >= limit
      raise RateLimitExceeded
    end

    Rails.cache.write(cache_key, current_count + 1, expires_in: period)
    true
  end

  def rate_limit_exceeded_response
    respond_to do |format|
      format.html do
        redirect_back fallback_location: root_path, alert: I18n.t("errors.rate_limit_exceeded")
      end
      format.json do
        render json: { error: I18n.t("errors.rate_limit_exceeded") }, status: :too_many_requests
      end
      format.any do
        head :too_many_requests
      end
    end
  end

  # Convenience methods for common rate limiting scenarios
  def check_password_reset_rate_limit!
    check_rate_limit!(
      key: "password_reset:#{request.remote_ip}",
      limit: SystemSetting.password_reset_rate_limit,
      period: SystemSetting.password_reset_rate_period
    )
  end

  def check_api_rate_limit!
    identifier = Current.user&.id || request.remote_ip
    check_rate_limit!(
      key: "api:#{identifier}",
      limit: SystemSetting.api_rate_limit,
      period: SystemSetting.api_rate_period
    )
  end
end

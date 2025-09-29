Rails.application.config.x.livestore = ActiveSupport::OrderedOptions.new
Rails.application.config.x.livestore.base_url = ENV.fetch("LIVESTORE_BASE_URL", "https://livestore.dev/api")
Rails.application.config.x.livestore.enabled = ActiveModel::Type::Boolean.new.cast(
  ENV.fetch("LIVESTORE_ENABLED", "true")
)

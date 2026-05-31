# frozen_string_literal: true

module Collavre
  module IntegrationSettings
    # Value object describing a registered integration setting key.
    #
    # @!attribute [r] key
    #   @return [Symbol] canonical key identifier (e.g. :slack_client_id)
    # @!attribute [r] category
    #   @return [String] grouping for the admin UI (e.g. "slack", "google_oauth")
    # @!attribute [r] sensitive
    #   @return [Boolean] when true the value is masked in the admin UI
    # @!attribute [r] requires_restart
    #   @return [Boolean] when true the admin UI surfaces a "restart required" badge
    # @!attribute [r] env_var
    #   @return [String] name of the ENV variable used as fallback / seed source
    # @!attribute [r] default
    #   @return [String, nil] static default returned when neither DB nor ENV has a value
    KeyDefinition = Struct.new(
      :key,
      :category,
      :sensitive,
      :requires_restart,
      :env_var,
      :default,
      keyword_init: true
    )
  end
end

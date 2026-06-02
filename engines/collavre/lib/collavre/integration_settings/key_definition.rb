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
    # @!attribute [r] input_type
    #   @return [Symbol] admin UI input widget: :string (default, single line) or :textarea
    # @!attribute [r] admin_visible
    #   @return [Boolean] when false the key is resolvable but hidden from the admin UI
    KeyDefinition = Struct.new(
      :key,
      :category,
      :sensitive,
      :requires_restart,
      :env_var,
      :default,
      :input_type,
      :admin_visible,
      keyword_init: true
    )
  end
end

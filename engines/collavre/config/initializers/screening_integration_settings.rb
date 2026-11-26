# frozen_string_literal: true

registry = Collavre::IntegrationSettings::Registry.instance
registry.register(:typesafe_api_key, category: "llm", sensitive: true)
registry.register(:typesafe_api_base, category: "llm", sensitive: false)

# frozen_string_literal: true

Rails.application.config.to_prepare do
  Collavre::FeatureCardRegistry.register(:kollavy, {
    icon: "🥬",
    title_key: "collavre.comments.empty_state.cards.kollavy.title",
    description_key: "collavre.comments.empty_state.cards.kollavy.description",
    available: -> { Collavre::Kollavy.agent.present? },
    guide: true
  })
end

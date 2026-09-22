# frozen_string_literal: true

get "history/:id", to: "creative_change_sets#show", as: :change_set
post "history/:id/apply", to: "creative_change_sets#apply", as: :apply_change_set

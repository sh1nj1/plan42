# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class ModelsController < BaseController
        AVAILABLE_MODELS = [
          { id: "gemini-2.5-flash", owned_by: "google" },
          { id: "gemini-2.5-pro", owned_by: "google" },
          { id: "gemini-2.0-flash", owned_by: "google" }
        ].freeze

        def index
          models = AVAILABLE_MODELS.map do |m|
            {
              id: m[:id],
              object: "model",
              created: 1_700_000_000,
              owned_by: m[:owned_by]
            }
          end

          render json: { object: "list", data: models }
        end
      end
    end
  end
end

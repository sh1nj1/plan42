# frozen_string_literal: true

module Collavre
  # Raised inside collavre-core API v1 controllers to produce the canonical
  # single-message JSON envelope `{ error: "<message>" }` at a chosen status,
  # via the rescue_from in Collavre::Api::V1::BaseController.
  #
  # NOTE: this is the collavre-core `{error: "str"}` shape only. It is NOT for
  # the 422 validation-array shape `{errors: [...]}` (client retry contract),
  # nor the OpenAI-nested shape in collavre_completion_api. Do not route those
  # through this class.
  class ApiError < StandardError
    attr_reader :status

    def initialize(message, status: :unprocessable_entity)
      super(message)
      @status = status
    end
  end
end

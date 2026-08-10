# frozen_string_literal: true

module Collavre
  # Presentation-only first-run flow for the desktop CLI Proxy setup.
  # Installation and credential generation are deliberately not wired here yet.
  class DesktopSetupController < ApplicationController
    allow_unauthenticated_access

    STEPS = %w[account install adapters ready].freeze

    def show
      @step = params[:step].to_s
      @step = STEPS.first unless STEPS.include?(@step)
    end
  end
end

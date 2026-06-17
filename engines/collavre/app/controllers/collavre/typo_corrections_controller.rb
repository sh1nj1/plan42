module Collavre
  # Session-authenticated endpoint backing the inline typo-correction UI. The
  # frontend also gates by device/location, but we re-check here (fail closed)
  # before spending an LLM call, and echo the user's auto-apply threshold so the
  # client never has to hardcode it.
  class TypoCorrectionsController < ApplicationController
    def create
      user = Current.user
      device = params[:device].to_s
      location = params[:location].presence || "chat"

      unless user.typo_correction_active_for?(device: device, location: location)
        return render json: { edits: [], threshold: user.typo_correction_threshold }
      end

      edits = TypoCorrector.new.correct(params[:text])
      render json: { edits: edits, threshold: user.typo_correction_threshold }
    end
  end
end

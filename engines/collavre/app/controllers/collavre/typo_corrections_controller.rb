module Collavre
  # Session-authenticated endpoint backing the inline typo-correction UI. The
  # frontend also gates by device/location, but we re-check here (fail closed)
  # before spending an LLM call, and echo the user's auto-apply threshold so the
  # client never has to hardcode it.
  class TypoCorrectionsController < ApplicationController
    # The client debounce is only a hint — a scripted/compromised page can loop
    # this endpoint with arbitrary text, and every accepted call spends an LLM
    # request. Bound both the call rate and the per-call size server-side. The
    # chat composer is short text; anything larger is not a typo-correction case.
    MAX_TEXT_LENGTH = 4_000
    RATE_LIMIT = 120          # requests
    RATE_PERIOD = 1.minute    # ...per user per minute

    def create
      user = Current.user
      device = params[:device].to_s
      location = params[:location].presence || "chat"
      text = params[:text].to_s

      unless user.typo_correction_active_for?(device: device, location: location)
        return render json: { edits: [], threshold: user.typo_correction_threshold }
      end

      # Oversized input: skip the LLM entirely (return no edits, not an error —
      # this is a background affordance, not a user-facing failure).
      if text.length > MAX_TEXT_LENGTH
        return render json: { edits: [], threshold: user.typo_correction_threshold }
      end

      # Raises RateLimitExceeded -> 429 (DynamicRateLimiting), which the client
      # treats as "no suggestions this round".
      check_rate_limit!(key: "typo_correction:#{user.id}", limit: RATE_LIMIT, period: RATE_PERIOD)

      edits = TypoCorrector.new.correct(text)
      render json: { edits: edits, threshold: user.typo_correction_threshold }
    end
  end
end

module Collavre
  class LandingController < ApplicationController
    allow_unauthenticated_access

    # The demo video/poster URLs live in config/locales/landing.*.yml as full
    # absolute URLs pointing at the hosted assets. Nothing to resolve here — the
    # view reads them directly, so the landing page has no dependency on the
    # Creatives model and the URLs work from any environment (preview included).
    def show; end
  end
end

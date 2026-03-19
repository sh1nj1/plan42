module Collavre
  class LandingController < ApplicationController
    allow_unauthenticated_access

    def show
      redirect_to creatives_path if authenticated?
    end
  end
end

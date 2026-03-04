module Collavre
  class GamesController < ApplicationController
    skip_before_action :authenticate, only: [ :tetris ]

    def tetris
      render layout: false
    end
  end
end

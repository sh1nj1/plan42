module Collavre
  class EmailsController < ApplicationController
    def index
      @emails = Email.order(created_at: :desc).limit(50)
    end

    def show
      @email = Email.find(params[:id])
    end
  end
end

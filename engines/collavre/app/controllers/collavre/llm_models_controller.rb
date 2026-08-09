module Collavre
  class LlmModelsController < ApplicationController
    def destroy
      LlmModel.find(params[:id]).destroy!
      head :no_content
    end
  end
end

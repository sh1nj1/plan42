module Collavre
  class LlmModelsController < ApplicationController
    def destroy
      LlmModel.find_by(id: params[:id])&.destroy!
      head :no_content
    end
  end
end

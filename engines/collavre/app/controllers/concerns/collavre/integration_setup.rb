# frozen_string_literal: true

module Collavre
  module IntegrationSetup
    extend ActiveSupport::Concern

    private

    def set_creative
      @creative = Collavre::Creative.find(params[:creative_id])
    end

    def set_origin
      @origin = @creative.effective_origin
    end
  end
end

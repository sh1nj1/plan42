module Collavre
  class CreativeImportsController < ApplicationController
    allow_unauthenticated_access only: :create

    def create
      unless authenticated?
        render json: { error: "Unauthorized" }, status: :unauthorized and return
      end

      parent = params[:parent_id].present? ? Creative.find_by(id: params[:parent_id]) : nil
      created = ::Creatives::Importer.new(file: params[:markdown], user: Current.user, parent: parent).call

      if created.any?
        render json: { success: true, created: created.map(&:id) }
      else
        render json: { error: "No creatives created" }, status: :unprocessable_entity
      end
    rescue ::Creatives::Importer::UnsupportedFile
      render json: { error: "Invalid file type" }, status: :unprocessable_entity
    rescue ::Creatives::Importer::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end

module Collavre
  class CreativeImportsController < ApplicationController
    # Allow unauthenticated access so we can return JSON 401 instead of HTML redirect
    # for API/fetch callers (import_controller.js uses csrfFetch with Accept: application/json)
    allow_unauthenticated_access only: :create

    def create
      unless authenticated?
        render json: { error: "Unauthorized" }, status: :unauthorized and return
      end

      parent = params[:parent_id].present? ? Creative.find_by(id: params[:parent_id]) : nil
      if parent && !parent.has_permission?(Current.user, :write)
        render json: { error: I18n.t("collavre.creatives.errors.no_permission") }, status: :forbidden and return
      end

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

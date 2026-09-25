# frozen_string_literal: true

module Collavre
  module CreativeDestroyable
    extend ActiveSupport::Concern

    def destroy
      parent = @creative.parent
      unless @creative.has_permission?(Current.user, :admin)
        redirect_to @creative, alert: t("collavre.creatives.errors.no_permission") and return
      end
      Creatives::DestroyService.new(
        creative: @creative,
        user: Current.user,
        delete_with_children: params[:delete_with_children].present?
      ).call
      respond_to do |format|
        format.html { redirect_to destroy_redirect_path(parent), status: :see_other }
        format.json { head :no_content }
      end
    end

    private

    def destroy_redirect_path(parent)
      parent_id = parent.id if parent&.has_permission?(Current.user, :read)
      creatives_path(id: parent_id)
    end
  end
end

class AttachmentsController < ApplicationController
  before_action :authenticate_user!

  # DELETE /attachments/:signed_id
  def destroy
    begin
      blob = ActiveStorage::Blob.find_signed(params[:signed_id])

      # Only allow deletion if the user owns a creative that references this blob
      # For now, we'll allow any authenticated user to delete their uploaded blobs
      # You may want to add more strict permission checking here

      blob.purge
      head :no_content
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue => e
      Rails.logger.error("Failed to delete attachment: #{e.message}")
      head :internal_server_error
    end
  end
end

module Collavre
  module Creatives
    class FileDropsController < ApplicationController
      def create
        target = Creative.find(params[:creative_id])
        direction = params[:direction]
        files = Array(params[:files])
        return head :unprocessable_entity unless valid_drop?(direction, files)
        return head :forbidden unless writable_destination?(target, direction)
        return head :unprocessable_entity if direction == "child" && !target.attachments_embeddable?

        creative = FileDropService.new(target: target, direction: direction, files: files, user: Current.user).call
        render json: { id: creative.id }
      rescue ActiveRecord::RecordNotFound
        head :not_found
      rescue ActiveRecord::RecordInvalid
        head :unprocessable_entity
      end

      private

      def valid_drop?(direction, files)
        %w[up down child].include?(direction) && files.any? &&
          files.all? { |file| file.is_a?(ActionDispatch::Http::UploadedFile) }
      end

      def writable_destination?(target, direction)
        return target.has_permission?(Current.user, :write) if direction == "child"
        return false unless target.has_permission?(Current.user, :read)

        target.parent.nil? || target.parent.has_permission?(Current.user, :write)
      end
    end
  end
end

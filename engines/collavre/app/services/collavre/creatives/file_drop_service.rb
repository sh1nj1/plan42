module Collavre
  module Creatives
    class FileDropService
      def initialize(target:, direction:, files:, user:)
        @target, @direction, @files, @user = target, direction, files, user
        @blobs = []
      end

      def call
        @files.each { |file| upload(file) }
        Creative.transaction do
          creative = destination
          @blobs.each { |blob| creative.embed_attachment_blob!(blob) } if @direction == "child"
          creative
        end
      rescue StandardError
        @blobs.each { |blob| blob.purge unless blob.attachments.exists? }
        raise
      end

      private

      def upload(file)
        blob = ActiveStorage::Blob.create_after_unfurling!(
          io: file.tempfile, filename: file.original_filename, content_type: file.content_type
        )
        @blobs << blob
        blob.upload_without_unfurling(file.tempfile)
      end

      def attachment_description
        title = "<p>#{ERB::Util.html_escape(@files.first.original_filename)}</p>"
        title + @blobs.map { |blob| @target.attachment_node_html(blob) }.join
      end

      def destination
        return @target if @direction == "child"

        result = CreateService.new(
          creative_params: { parent_id: @target.parent_id, description: attachment_description }, user: @user,
          before_id: (@target.id if @direction == "up"), after_id: (@target.id if @direction == "down")
        ).call
        raise ActiveRecord::RecordInvalid, result.creative unless result.success?

        result.creative
      end
    end
  end
end

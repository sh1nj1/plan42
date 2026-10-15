module Collavre
  # Cache only renderer output; authorization is always checked by the controller.
  class PptPreview
    def self.slides(blob)
      raise PptRenderer::InvalidArchive if blob.byte_size > PptRenderer::MAX_TOTAL_BYTES

      Rails.cache.fetch([ "ppt-preview-v1", blob.key, I18n.locale ], expires_in: 7.days) do
        blob.open { |file| PptRenderer.new(file, inline_media: true).render }
      end
    end
  end
end

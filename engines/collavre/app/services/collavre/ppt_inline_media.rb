module Collavre
  # Bound serialized image occurrences before expanding or copying data URIs.
  module PptInlineMedia
    private

    def inline_picture_source(entry)
      type = Marcel::MimeType.for(name: File.basename(entry.name))
      return "" unless type&.start_with?("image/")

      data = read_entry(entry)
      prefix = "data:#{type};base64,"
      bytes = prefix.bytesize + 4 * ((data.bytesize + 2) / 3)
      @inline_media_bytes += bytes
      raise self.class::InvalidArchive if @inline_media_bytes > self.class::MAX_RENDERED_BYTES

      @inline_media_cache[entry.name] ||= "#{prefix}#{Base64.strict_encode64(data)}"
    end
  end
end

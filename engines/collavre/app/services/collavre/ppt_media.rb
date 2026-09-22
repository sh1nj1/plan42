require "uri"

module Collavre
  # Preserve safe external navigation and bounded picture crop rectangles.
  module PptMedia
    private

    def linked_run(run, text)
      link = run.at_xpath("./*[local-name()='rPr']/*[local-name()='hlinkClick']")
      part = @xml_cache&.key(run.document)
      return text unless link && part

      relationship = relationships_for(part)[relationship_id(link)]
      return text unless relationship && relationship[:external] && relationship[:type].end_with?("/hyperlink")

      target = relationship[:target]
      return text unless safe_hyperlink?(target)

      %(<a href="#{ERB::Util.html_escape(target)}">#{text}</a>)
    end

    def safe_hyperlink?(target)
      return false unless target.length <= 4096 && !target.match?(/[[:space:][:cntrl:]\\]/)

      uri = URI.parse(target)
      case uri.scheme&.downcase
      when "http", "https" then uri.host.present?
      when "mailto" then uri.opaque.present?
      else false
      end
    rescue URI::InvalidURIError
      false
    end

    def picture_crop(picture)
      rect = picture.at_xpath("./*[local-name()='blipFill']/*[local-name()='srcRect']")
      return unless rect

      values = %w[l t r b].map { |key| rect[key] || "0" }
      return unless values.all? { |value| value.match?(/\A-?\d{1,7}\z/) }

      crop = values.map { |value| value.to_i / 100_000.0 }
      return unless crop.all? { |value| value.between?(-1, 1) }
      return unless (1 - crop[0] - crop[2]).between?(0.001, 3) && (1 - crop[1] - crop[3]).between?(0.001, 3)

      crop
    end
  end
end

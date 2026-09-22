module Collavre
  # Backgrounds are outside spTree and inherit independently of master shapes.
  module PptBackgrounds
    private

    def background_fill(slide)
      documents = [ slide ] + @inherited_parts.to_a.map { |part| part[:document] }
      background = documents.filter_map do |document|
        document.at_xpath("/*/*[local-name()='cSld']/*[local-name()='bg']")
      end.first
      properties = background&.at_xpath("./*[local-name()='bgPr']")
      properties ? properties.element_children.first : background_reference_fill(background&.at_xpath("./*[local-name()='bgRef']"))
    end

    def background_reference_fill(reference)
      return unless reference && @theme

      shape_style_entry(reference, "fillRef")
    end

    def background_format(slide)
      fill = background_fill(slide)
      fill_format(fill).reverse_merge(fill: "#ffffff")
    end

    def fill_format(fill, size = @slide_size)
      case fill&.name
      when "gradFill" then { fill: ppt_color(fill.at_xpath("./*[local-name()='gsLst']/*[local-name()='gs']")), background: gradient_background(fill, size) }
      when "pattFill" then { fill: ppt_color(fill.at_xpath("./*[local-name()='bgClr']")), background: pattern_background(fill) }
      else { fill: ppt_color(fill) }.compact
      end
    end

    def gradient_background(fill, size = @slide_size)
      stops = fill.xpath("./*[local-name()='gsLst']/*[local-name()='gs']")
      return unless stops.length.between?(2, 100)

      values = stops.map { |stop| [ background_number(stop["pos"], 0..100_000), ppt_color(stop) ] }
      return if values.flatten.any?(&:nil?)

      linear = fill.at_xpath("./*[local-name()='lin']")
      angle = background_number(linear&.[]("ang") || "0", 0..21_600_000)
      return unless angle

      path = fill.at_xpath("./*[local-name()='path']")
      return if path

      { type: "linear", angle: background_angle(angle, linear, size),
        stops: values.sort_by(&:first).map { |position, color| [ position / 1000.0, color ] } }
    end

    def background_angle(angle, linear, size)
      degrees = angle / 60_000.0
      return degrees unless %w[1 true on].include?(linear&.[]("scaled"))

      radians = degrees * Math::PI / 180
      width, height = size
      Math.atan2(height * Math.sin(radians), width * Math.cos(radians)) * 180 / Math::PI % 360
    end

    def pattern_background(fill)
      foreground = ppt_color(fill.at_xpath("./*[local-name()='fgClr']"))
      background = ppt_color(fill.at_xpath("./*[local-name()='bgClr']"))
      return unless foreground && background

      { type: "pattern", preset: fill["prst"], foreground: foreground, background: background }
    end

    def background_number(value, range)
      return unless value&.match?(/\A[0-9]{1,10}\z/) && range.cover?(value.to_i)

      value.to_i
    end

    def background_picture(slide)
      fill = background_fill(slide)
      return "" unless fill&.name == "blipFill"

      picture_fill_markup(fill, "ppt-slide-background ppt-slide-image")
    end

    def picture_fill_markup(fill, classes, part = @xml_cache.key(fill.document))
      # Theme fill copies retain their owning document, so relationship IDs are
      # resolved against the source part rather than the current slide.
      relationship = part && relationships_for(part)[relationship_id(fill.at_xpath("./*[local-name()='blip']"), "embed")]
      return "" unless relationship && !relationship[:external] && relationship[:type].end_with?("/image")

      entry = @zip.find_entry(relationship[:path])
      return "" unless entry

      blob = blob_for(entry)
      src = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
      wrapper = Nokogiri::XML::Node.new("picture", fill.document)
      wrapper.add_child(fill.dup)
      %(<div class="#{classes}"#{format_attribute(crop: picture_crop(wrapper))}><img src="#{ERB::Util.html_escape(src)}" alt=""></div>)
    end
  end
end

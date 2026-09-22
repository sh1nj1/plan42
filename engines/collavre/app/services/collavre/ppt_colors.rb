module Collavre
  # Resolve theme references before serializing strictly hexadecimal colors.
  module PptColors
    private

    def prepare_colors(slide)
      parts = @inherited_parts.to_a
      @color_documents = [ slide ] + parts.map { |part| part[:document] }
      relationship_sets = parts.reverse.map { |part| part[:relationships] }
      relationship_sets << relationships_for("ppt/presentation.xml")
      relationship = relationship_sets.flat_map(&:values).find { |item| item[:type].end_with?("/theme") }
      @theme = relationship && xml_document(relationship[:path])
    end

    def ppt_color(node)
      color = node&.element_children&.find { |child| %w[srgbClr schemeClr sysClr].include?(child.name) }
      return unless color

      value = color.name == "schemeClr" ? theme_color(color["val"]) : literal_color(color)
      return unless value&.match?(/\A[0-9a-f]{6}\z/i)
      return "##{value}" if color.element_children.empty?

      rgb = value.scan(/../).map { |channel| channel.to_i(16) / 255.0 }
      color.element_children.each { |modifier| rgb = transform_color(rgb, modifier) }
      "#" + rgb.map { |channel| format("%02X", (channel.clamp(0, 1) * 255).round) }.join + color_alpha(color)
    end

    def color_alpha(color)
      alpha = color.element_children.reduce(1.0) do |current, modifier|
        amount = alpha_amount(modifier)
        next current unless amount

        value = case modifier.name
        when "alpha" then amount
        when "alphaMod" then current * amount
        when "alphaOff" then current + amount
        end
        value.clamp(0, 1)
      end
      alpha == 1 ? "" : format("%02X", (alpha * 255).round)
    end

    def alpha_amount(modifier)
      limits = { "alpha" => 0..100_000, "alphaMod" => 0..2_147_483_647, "alphaOff" => -100_000..100_000 }
      range = limits[modifier.name]
      value = modifier["val"]
      return unless range && value&.match?(/\A[+-]?[0-9]{1,10}\z/)

      integer = value.to_i
      integer / 100_000.0 if range.cover?(integer)
    end

    def literal_color(node)
      node&.[](node.name == "sysClr" ? "lastClr" : "val")
    end

    def theme_color(name)
      return unless @theme

      mapping = color_mapping
      name = mapping&.[](name) || { "bg1" => "lt1", "tx1" => "dk1", "bg2" => "lt2", "tx2" => "dk2" }[name] || name
      scheme = @theme.at_xpath("//*[local-name()='clrScheme']")
      slot = scheme&.element_children&.find { |child| child.name == name }
      literal_color(slot&.element_children&.first)
    end

    def color_mapping
      master = @color_documents.to_a.last&.at_xpath("//*[local-name()='clrMap']")
      @color_documents.to_a.each do |document|
        override = document.at_xpath("//*[local-name()='clrMapOvr']")
        next unless override
        return master if override.at_xpath("./*[local-name()='masterClrMapping']")

        return override.at_xpath("./*[local-name()='overrideClrMapping']")
      end
      master
    end

    def transform_color(rgb, modifier)
      amount = Float(modifier["val"], exception: false)
      return rgb unless amount&.finite?

      amount /= 100_000
      case modifier.name
      when "tint" then rgb.map { |channel| channel * amount + 1 - amount }
      when "shade" then rgb.map { |channel| channel * amount }
      when "lumMod", "lumOff" then transform_luminance(rgb, modifier.name, amount)
      else rgb
      end
    end

    def transform_luminance(rgb, kind, amount)
      low, high = rgb.minmax
      light = (low + high) / 2
      target = (kind == "lumMod" ? light * amount : light + amount).clamp(0, 1)
      chroma = high - low
      return [ target ] * 3 if chroma.zero?

      saturation = chroma / (1 - (2 * light - 1).abs)
      new_chroma = (1 - (2 * target - 1).abs) * saturation
      rgb.map { |channel| (channel - low) / chroma * new_chroma + target - new_chroma / 2 }
    end
  end
end

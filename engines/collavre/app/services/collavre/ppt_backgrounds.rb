module Collavre
  # Backgrounds are outside spTree and inherit independently of master shapes.
  module PptBackgrounds
    private

    def slide_background(slide)
      documents = [ slide ] + @inherited_parts.to_a.map { |part| part[:document] }
      background = documents.filter_map do |document|
        document.at_xpath("/*/*[local-name()='cSld']/*[local-name()='bg']")
      end.first
      properties = background&.at_xpath("./*[local-name()='bgPr']")
      fill = if properties
        properties.at_xpath("./*[local-name()='solidFill']")
      else
        background_reference_fill(background&.at_xpath("./*[local-name()='bgRef']"))
      end
      ppt_color(fill) || "#ffffff"
    end

    def background_reference_fill(reference)
      return unless reference && @theme

      index = Integer(reference["idx"].to_s, 10, exception: false)
      return unless index && index.positive? && index != 1000

      list_name, offset = index > 1000 ? [ "bgFillStyleLst", 1001 ] : [ "fillStyleLst", 1 ]
      list = @theme.at_xpath("//*[local-name()='fmtScheme']/*[local-name()='#{list_name}']")
      fill = list&.element_children&.[](index - offset)
      return unless fill&.name == "solidFill"

      resolve_background_placeholder(fill.dup, reference)
    end

    def resolve_background_placeholder(fill, reference)
      placeholder = fill.at_xpath("./*[local-name()='schemeClr' and @val='phClr']")
      return fill unless placeholder

      color = ppt_color(reference)
      return unless color

      placeholder.name = "srgbClr"
      placeholder["val"] = color.delete_prefix("#")
      fill
    end
  end
end

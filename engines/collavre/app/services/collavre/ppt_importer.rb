require "erb"
require "nokogiri"
require "pathname"
require "stringio"
require "zip"

module Collavre
  class PptImporter
    GRID_SIZE = 24
    DEFAULT_SLIDE_SIZE = [ 12_192_000, 6_858_000 ].freeze

    class << self
      # Imports one PPTX slide per Creative. The generated HTML keeps the slide,
      # shape/group, text, image, table, and chart hierarchy while a small CSS
      # grid approximates the original coordinates responsively.
      def import(file, parent:, user:, create_root: false, filename: nil)
        new(file, parent: parent, user: user, create_root: create_root, filename: filename).import
      end
    end

    def initialize(file, parent:, user:, create_root:, filename:)
      @file = file
      @parent = parent
      @user = user
      @create_root = create_root
      @filename = filename
      @blob_cache = {}
    end

    def import
      created = []

      Zip::File.open(@file) do |zip|
        @zip = zip
        @slide_size = presentation_slide_size
        root = create_import_root(created)
        sequence = next_sequence(root)

        ordered_slide_paths.each_with_index do |slide_path, index|
          slide = xml_document(slide_path)
          next unless slide

          html = render_slide(slide, slide_path, index + 1)
          creative = Creative.create!(
            user: @user,
            parent: root,
            description: html,
            sequence: sequence
          )
          created << creative
          sequence += 1
        end
      end

      Creative::RealtimeBroadcastable.broadcast_batch_created(created)
      created
    end

    private

    def create_import_root(created)
      return @parent unless @create_root

      title = @filename ? File.basename(@filename, File.extname(@filename)) : "Presentation"
      root = Creative.create!(
        user: @user,
        parent: @parent,
        description: ERB::Util.html_escape(title),
        sequence: next_sequence(@parent)
      )
      created << root
      root
    end

    def next_sequence(parent)
      siblings = parent ? parent.children : Creative.roots
      (siblings.maximum(:sequence) || -1) + 1
    end

    # slideN.xml filenames do not necessarily reflect presentation order after
    # users reorder slides. Follow presentation.xml relationships first.
    def ordered_slide_paths
      presentation = xml_document("ppt/presentation.xml")
      if presentation
        relationships = relationships_for("ppt/presentation.xml")
        paths = presentation.xpath("//*[local-name()='sldId']").filter_map do |slide_id|
          relationship = relationships[relationship_id(slide_id)]
          relationship&.fetch(:path, nil) if relationship&.fetch(:type, "")&.end_with?("/slide")
        end
        return paths if paths.any?
      end

      @zip.glob("ppt/slides/slide*.xml")
        .sort_by { |entry| entry.name[/slide(\d+)/, 1].to_i }
        .map(&:name)
    end

    def presentation_slide_size
      presentation = xml_document("ppt/presentation.xml")
      size = presentation&.at_xpath("//*[local-name()='sldSz']")
      width = size&.[]("cx").to_i
      height = size&.[]("cy").to_i
      return DEFAULT_SLIDE_SIZE if width <= 0 || height <= 0

      [ width, height ]
    end

    def render_slide(slide, slide_path, slide_number)
      namespaces = slide.collect_namespaces
      relationships = relationships_for(slide_path)
      shape_tree = slide.at_xpath("//p:cSld/p:spTree", namespaces)
      elements = shape_tree ? render_nodes(shape_tree.element_children, namespaces, relationships, @slide_size) : ""
      notes = render_notes(relationships)
      ratio_class = slide_ratio_class(*@slide_size)

      <<~HTML.squish
        <div class="ppt-slide #{ratio_class}" data-ppt-slide="#{slide_number}"
             data-ppt-width="#{@slide_size.first}" data-ppt-height="#{@slide_size.last}">
          <div class="ppt-slide-layout">#{elements}</div>
        </div>
        #{notes}
      HTML
    end

    def render_nodes(nodes, namespaces, relationships, bounds)
      nodes.filter_map do |node|
        case node.name
        when "sp"
          render_text_shape(node, namespaces, bounds)
        when "pic"
          render_picture(node, namespaces, relationships, bounds)
        when "graphicFrame"
          render_graphic_frame(node, namespaces, relationships, bounds)
        when "grpSp"
          render_group(node, namespaces, relationships, bounds)
        end
      end.join
    end

    def render_text_shape(shape, namespaces, bounds)
      paragraphs = shape.xpath("./p:txBody/a:p", namespaces).filter_map do |paragraph|
        render_paragraph(paragraph, namespaces)
      end
      return if paragraphs.empty?

      placeholder = shape.at_xpath("./p:nvSpPr/p:nvPr/p:ph", namespaces)&.[]("type")
      kind = %w[title ctrTitle subTitle].include?(placeholder) ? "title" : "text"
      classes = element_classes("ppt-slide-#{kind}", transform_for(shape, namespaces), bounds)
      %(<div class="#{classes}">#{paragraphs.join}</div>)
    end

    def render_paragraph(paragraph, namespaces)
      content = paragraph.element_children.filter_map do |child|
        case child.name
        when "r", "fld"
          render_text_run(child, namespaces)
        when "br"
          "<br>"
        end
      end.join
      content = ERB::Util.html_escape(paragraph.xpath(".//a:t", namespaces).map(&:text).join) if content.empty?
      return if ActionController::Base.helpers.strip_tags(content).strip.empty? && !content.include?("<br>")

      "<p>#{content}</p>"
    end

    def render_text_run(run, namespaces)
      text = ERB::Util.html_escape(run.xpath(".//a:t", namespaces).map(&:text).join)
      properties = run.at_xpath("./a:rPr", namespaces)
      text = "<strong>#{text}</strong>" if truthy_xml_attribute?(properties&.[]("b"))
      text = "<em>#{text}</em>" if truthy_xml_attribute?(properties&.[]("i"))
      text = "<u>#{text}</u>" if properties&.[]("u").present? && properties["u"] != "none"
      text
    end

    def render_picture(picture, namespaces, relationships, bounds)
      blip = picture.at_xpath(".//a:blip", namespaces)
      relationship = relationships[relationship_id(blip, "embed")]
      return unless relationship

      entry = @zip.find_entry(relationship[:path])
      return unless entry

      blob = blob_for(entry)
      metadata = picture.at_xpath("./p:nvPicPr/p:cNvPr", namespaces)
      alt = metadata&.[]("descr").presence || metadata&.[]("name").presence || blob.filename.to_s
      classes = element_classes("ppt-slide-image", transform_for(picture, namespaces), bounds)
      src = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
      %(<div class="#{classes}"><img src="#{src}" alt="#{ERB::Util.html_escape(alt)}"></div>)
    end

    def blob_for(entry)
      @blob_cache[entry.name] ||= begin
        filename = File.basename(entry.name)
        content_type = Marcel::MimeType.for(name: filename) || "application/octet-stream"
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(entry.get_input_stream.read),
          filename: filename,
          content_type: content_type
        )
      end
    end

    def render_graphic_frame(frame, namespaces, relationships, bounds)
      content = if frame.at_xpath(".//*[local-name()='tbl']")
        render_table(frame.at_xpath(".//*[local-name()='tbl']"), namespaces)
      elsif (chart = frame.at_xpath(".//*[local-name()='chart']"))
        render_chart(relationships[relationship_id(chart)])
      end
      return if content.blank?

      classes = element_classes("ppt-slide-graphic", transform_for(frame, namespaces), bounds)
      %(<div class="#{classes}">#{content}</div>)
    end

    def render_table(table, namespaces)
      rows = table.xpath("./a:tr", namespaces).map do |row|
        cells = row.xpath("./a:tc", namespaces).map do |cell|
          content = cell.xpath("./a:txBody/a:p", namespaces).filter_map do |paragraph|
            render_paragraph(paragraph, namespaces)
          end.join
          span = cell.at_xpath("./a:tcPr/a:gridSpan", namespaces)&.[]("val").to_i
          colspan = span > 1 ? %( colspan="#{span}") : ""
          "<td#{colspan}>#{content}</td>"
        end
        "<tr>#{cells.join}</tr>"
      end
      %(<table class="ppt-slide-table"><tbody>#{rows.join}</tbody></table>)
    end

    def render_chart(relationship)
      chart = relationship && xml_document(relationship[:path])
      return unless chart

      title = chart.xpath("//*[local-name()='title']//*[local-name()='t']").map(&:text).join(" ").strip
      series = chart.xpath("//*[local-name()='ser']").filter_map do |item|
        name = item.xpath("./*[local-name()='tx']//*[local-name()='v']").map(&:text).join(" ").strip
        categories = indexed_chart_values(item, "cat")
        values = indexed_chart_values(item, "val")
        next if name.blank? && categories.empty? && values.empty?

        [ name, categories, values ]
      end
      return if title.blank? && series.empty?

      caption = title.presence || I18n.t("collavre.creatives.index.imported_chart")
      rows = series.map do |name, categories, values|
        pairs = [ categories.length, values.length ].max.times.map do |index|
          [ categories[index], values[index] ].compact.join(": ")
        end
        "<tr><th>#{ERB::Util.html_escape(name)}</th><td>#{ERB::Util.html_escape(pairs.join(", "))}</td></tr>"
      end
      %(<div class="ppt-slide-chart"><h3>#{ERB::Util.html_escape(caption)}</h3><table><tbody>#{rows.join}</tbody></table></div>)
    end

    def indexed_chart_values(series, axis)
      points = series.xpath("./*[local-name()='#{axis}']//*[local-name()='pt']")
      points.sort_by { |point| point["idx"].to_i }.map do |point|
        point.at_xpath("./*[local-name()='v']")&.text.to_s
      end
    end

    def render_group(group, namespaces, relationships, bounds)
      transform = transform_for(group, namespaces)
      children = render_nodes(group.element_children, namespaces, relationships, group_child_bounds(group, namespaces))
      return if children.blank?

      classes = element_classes("ppt-slide-group", transform, bounds)
      %(<div class="#{classes}">#{children}</div>)
    end

    def render_notes(relationships)
      relationship = relationships.values.find { |item| item[:type].end_with?("/notesSlide") }
      notes = relationship && xml_document(relationship[:path])
      return "" unless notes

      namespaces = notes.collect_namespaces
      paragraphs = notes.xpath("//p:sp", namespaces).filter_map do |shape|
        type = shape.at_xpath("./p:nvSpPr/p:nvPr/p:ph", namespaces)&.[]("type")
        next unless type.nil? || type == "body"

        shape.xpath("./p:txBody/a:p", namespaces).filter_map do |paragraph|
          render_paragraph(paragraph, namespaces)
        end.join.presence
      end
      return "" if paragraphs.empty?

      title = ERB::Util.html_escape(I18n.t("collavre.creatives.index.imported_speaker_notes"))
      %(<div class="ppt-slide-notes"><h3>#{title}</h3>#{paragraphs.join}</div>)
    end

    def transform_for(node, namespaces)
      transform = case node.name
      when "graphicFrame"
        node.at_xpath("./p:xfrm", namespaces)
      when "grpSp"
        node.at_xpath("./p:grpSpPr/a:xfrm", namespaces)
      else
        node.at_xpath("./p:spPr/a:xfrm", namespaces)
      end
      return unless transform

      offset = transform.at_xpath("./a:off", namespaces)
      extent = transform.at_xpath("./a:ext", namespaces)
      return unless offset && extent

      [ offset["x"].to_i, offset["y"].to_i, extent["cx"].to_i, extent["cy"].to_i ]
    end

    def group_child_bounds(group, namespaces)
      transform = group.at_xpath("./p:grpSpPr/a:xfrm", namespaces)
      extent = transform&.at_xpath("./a:chExt", namespaces)
      width = extent&.[]("cx").to_i
      height = extent&.[]("cy").to_i
      width.positive? && height.positive? ? [ width, height ] : @slide_size
    end

    def element_classes(kind, transform, bounds)
      classes = [ "ppt-slide-element", kind ]
      return classes.join(" ") unless transform

      x, y, width, height = transform
      bound_width, bound_height = bounds
      column = grid_start(x, bound_width)
      row = grid_start(y, bound_height)
      classes.concat([
        "ppt-col-#{column}",
        "ppt-col-span-#{grid_span(width, bound_width, column)}",
        "ppt-row-#{row}",
        "ppt-row-span-#{grid_span(height, bound_height, row)}"
      ])
      classes.join(" ")
    end

    def grid_start(offset, total)
      return 1 unless total.positive?

      ((offset.to_f / total) * GRID_SIZE).floor.clamp(0, GRID_SIZE - 1) + 1
    end

    def grid_span(length, total, start)
      return 1 unless total.positive?

      ((length.to_f / total) * GRID_SIZE).round.clamp(1, GRID_SIZE - start + 1)
    end

    def slide_ratio_class(width, height)
      ratio = width.to_f / height
      return "ppt-slide--portrait" if ratio < 0.9
      return "ppt-slide--square" if ratio < 1.2
      return "ppt-slide--standard" if ratio < 1.55

      "ppt-slide--wide"
    end

    def relationships_for(part_path)
      directory = File.dirname(part_path)
      relationships_path = File.join(directory, "_rels", "#{File.basename(part_path)}.rels")
      document = xml_document(relationships_path)
      return {} unless document

      document.xpath("//*[local-name()='Relationship']").to_h do |relationship|
        target = relationship["Target"].to_s
        [ relationship["Id"], {
          path: normalize_part_path(part_path, target),
          type: relationship["Type"].to_s
        } ]
      end
    end

    def normalize_part_path(part_path, target)
      return target.delete_prefix("/") if target.start_with?("/")

      Pathname.new(File.dirname(part_path)).join(target).cleanpath.to_s
    end

    def relationship_id(node, attribute = "id")
      return unless node

      node.attribute_with_ns(attribute, "http://schemas.openxmlformats.org/officeDocument/2006/relationships")&.value ||
        node["r:#{attribute}"]
    end

    def xml_document(path)
      entry = @zip.find_entry(path)
      Nokogiri::XML(entry.get_input_stream.read) if entry
    end

    def truthy_xml_attribute?(value)
      %w[1 true on].include?(value.to_s.downcase)
    end
  end
end

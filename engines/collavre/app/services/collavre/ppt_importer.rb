require "erb"
require "nokogiri"
require "pathname"
require "stringio"
require "zip"

module Collavre
  class PptImporter
    include PptBackgrounds
    include PptColors
    include PptParagraphs
    include PptFormatting
    include PptInheritance
    include PptArchive
    include PptGeometry
    class InvalidArchive < StandardError; end

    MAX_ENTRIES = 2_000
    MAX_ENTRY_BYTES = 20.megabytes
    MAX_TOTAL_BYTES = 100.megabytes
    GRID_SIZE = 24
    DEFAULT_SLIDE_SIZE = [ 12_192_000, 6_858_000 ].freeze

    class << self
      # Imports one PPTX slide per Creative. The generated HTML keeps the slide,
      # shape/group, text, image, table, and chart hierarchy with responsive
      # coordinates and validated presentation formatting.
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

      import_archive(created)

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

    def render_slide(slide, slide_path, slide_number)
      namespaces = slide.collect_namespaces
      relationships = relationships_for(slide_path)
      @placeholder_sources = placeholder_sources(relationships)
      prepare_colors(slide)
      shape_tree = slide.at_xpath("//p:cSld/p:spTree", namespaces)
      inherited = render_inherited_shapes(slide)
      elements = shape_tree ? render_nodes(shape_tree.element_children, namespaces, relationships, @slide_size) : ""
      notes = render_notes(relationships)
      ratio_class = slide_ratio_class(*@slide_size)

      <<~HTML.strip
        <div class="ppt-slide #{ratio_class}" data-ppt-slide="#{slide_number}"
             data-ppt-width="#{@slide_size.first}" data-ppt-height="#{@slide_size.last}"#{format_attribute(fill: slide_background(slide))}>
          <div class="ppt-slide-layout">#{inherited}#{elements}</div>
        </div>
        #{notes}
      HTML
    end

    def render_nodes(nodes, namespaces, relationships, bounds)
      nodes.filter_map do |node|
        next if @rendering_inherited && node.at_xpath("./*[local-name()='nvSpPr' or local-name()='nvPicPr' or local-name()='nvGraphicFramePr']//*[local-name()='ph']")

        case node.name
        when "sp"
          render_text_shape(node, namespaces, bounds)
        when "pic"
          render_picture(node, namespaces, relationships, bounds)
        when "graphicFrame"
          render_graphic_frame(node, namespaces, relationships, bounds)
        when "AlternateContent"
          branch = compatibility_branch(node)
          render_nodes(branch.element_children, namespaces, relationships, bounds) if branch
        when "grpSp"
          render_group(node, namespaces, relationships, bounds)
        end
      end.join
    end

    def render_text_shape(shape, namespaces, bounds)
      paragraphs = shape.xpath("./p:txBody/a:p", namespaces).filter_map do |paragraph|
        render_paragraph(paragraph, namespaces)
      end

      placeholder = shape.at_xpath("./p:nvSpPr/p:nvPr/p:ph", namespaces)&.[]("type")
      kind = %w[title ctrTitle subTitle].include?(placeholder) ? "title" : "text"
      classes = element_classes("ppt-slide-#{kind}", transform_for(shape, namespaces), bounds)
      %(<div class="#{classes}"#{format_attribute(shape_format(shape, namespaces, bounds))}>#{paragraphs.join}</div>)
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

      formatting = paragraph_format(paragraph, namespaces)
      bullet = formatting.delete(:bullet)
      content = %(<span class="ppt-bullet">#{ERB::Util.html_escape(bullet)} </span>) + content if bullet.present?
      %(<p#{format_attribute(formatting)}>#{content}</p>)
    end

    def render_text_run(run, namespaces)
      text = ERB::Util.html_escape(run.xpath(".//a:t", namespaces).map(&:text).join)
      properties = effective_run_properties(run, namespaces)
      text = "<strong>#{text}</strong>" if truthy_xml_attribute?(properties&.[]("b"))
      text = "<em>#{text}</em>" if truthy_xml_attribute?(properties&.[]("i"))
      text = "<u>#{text}</u>" if properties&.[]("u").present? && properties["u"] != "none"
      %(<span#{format_attribute(text_format(properties, namespaces))}>#{text}</span>)
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
      %(<div class="#{classes}"#{format_attribute(geometry_format(picture, namespaces, bounds))}><img src="#{src}" alt="#{ERB::Util.html_escape(alt)}"></div>)
    end

    def blob_for(entry)
      @blob_cache[entry.name] ||= begin
        filename = File.basename(entry.name)
        content_type = Marcel::MimeType.for(name: filename) || "application/octet-stream"
        data = read_entry(entry)
        blob = ActiveStorage::Blob.build_after_unfurling(
          io: StringIO.new(data),
          filename: filename,
          content_type: content_type
        )
        @blob_cache[entry.name] = blob
        blob.save!
        blob.upload_without_unfurling(StringIO.new(data))
        blob
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
      %(<div class="#{classes}"#{format_attribute(geometry_format(frame, namespaces, bounds))}>#{content}</div>)
    end

    def render_table(table, namespaces)
      rows = table.xpath("./a:tr", namespaces).map do |row|
        cells = row.xpath("./a:tc", namespaces).filter_map do |cell|
          next if truthy_xml_attribute?(cell["hMerge"]) || truthy_xml_attribute?(cell["vMerge"])

          content = cell.xpath("./a:txBody/a:p", namespaces).filter_map do |paragraph|
            render_paragraph(paragraph, namespaces)
          end.join
          span = cell["gridSpan"].to_i
          colspan = span > 1 ? %( colspan="#{span}") : ""
          rowspan = cell["rowSpan"].to_i > 1 ? %( rowspan="#{cell["rowSpan"].to_i}") : ""
          "<td#{colspan}#{rowspan}>#{content}</td>"
        end
        "<tr>#{cells.join}</tr>"
      end
      %(<table class="ppt-slide-table"><tbody>#{rows.join}</tbody></table>)
    end

    def render_chart(relationship)
      chart = relationship && xml_document(relationship[:path])
      return unless chart

      title = chart.xpath("//*[local-name()='title']//*[local-name()='t']").map(&:text).join(" ").strip
      series = chart_series(chart)
      return if title.blank? && series.empty?

      caption = title.presence || I18n.t("collavre.creatives.index.imported_chart")
      rows = series.map do |name, categories, values|
        pairs = (categories.keys | values.keys).sort.map do |index|
          [ categories[index], values[index] ].compact.join(": ")
        end
        "<tr><th>#{ERB::Util.html_escape(name)}</th><td>#{ERB::Util.html_escape(pairs.join(", "))}</td></tr>"
      end
      %(<div class="ppt-slide-chart"#{format_attribute(chart: line_chart_format(chart, series))}><h3>#{ERB::Util.html_escape(caption)}</h3><table><tbody>#{rows.join}</tbody></table></div>)
    end

    def chart_series(chart)
      chart.xpath("//*[local-name()='ser']").filter_map do |item|
        name = item.xpath("./*[local-name()='tx']//*[local-name()='v']").map(&:text).join(" ").strip
        categories = indexed_chart_values(item, "cat")
        values = indexed_chart_values(item, "val")
        next if name.blank? && categories.empty? && values.empty?

        [ name, categories, values ]
      end
    end

    def indexed_chart_values(series, axis)
      points = series.xpath("./*[local-name()='#{axis}']//*[local-name()='pt']")
      points.to_h do |point|
        [ point["idx"].to_i, point.at_xpath("./*[local-name()='v']")&.text.to_s ]
      end
    end

    def render_group(group, namespaces, relationships, bounds)
      transform = transform_for(group, namespaces)
      children = render_nodes(group.element_children, namespaces, relationships, group_child_bounds(group, namespaces))
      return if children.blank?

      classes = element_classes("ppt-slide-group", transform, bounds)
      %(<div class="#{classes}"#{format_attribute(geometry_format(group, namespaces, bounds))}>#{children}</div>)
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

    def truthy_xml_attribute?(value)
      %w[1 true on].include?(value.to_s.downcase)
    end
  end
end

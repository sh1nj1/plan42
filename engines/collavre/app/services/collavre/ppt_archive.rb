module Collavre
  # Bounded archive access and transaction lifecycle for PPT imports.
  module PptArchive
    private

    def import_archive(created)
      Creative.transaction(requires_new: true) do |transaction|
        transaction.after_rollback { @blob_cache.each_value(&:delete) }
        Zip::File.open(@file) do |zip|
          @zip = zip
          validate_archive!
          paths = ordered_slide_paths
          raise self.class::InvalidArchive if paths.empty?

          @slide_size = presentation_slide_size
          root = create_import_root(created)
          sequence = next_sequence(root)
          paths.each_with_index do |path, index|
            slide = xml_document(path)
            raise self.class::InvalidArchive unless slide

            created << Creative.create!(
              user: @user, parent: root,
              description: render_slide(slide, path, index + 1),
              sequence: sequence + index
            )
          end
        end
      end
    end

    def validate_archive!
      entries = @zip.entries
      raise self.class::InvalidArchive if entries.size > self.class::MAX_ENTRIES
      raise self.class::InvalidArchive if entries.any? { |entry| entry.size > self.class::MAX_ENTRY_BYTES }
      raise self.class::InvalidArchive if entries.sum(&:size) > self.class::MAX_TOTAL_BYTES

      @read_bytes = 0
      @entry_cache = {}
      @xml_cache = {}
    end

    def read_entry(entry)
      @entry_cache ||= {}
      return @entry_cache[entry.name] if @entry_cache.key?(entry.name)

      data = entry.get_input_stream do |stream|
        stream.read(self.class::MAX_ENTRY_BYTES + 1)
      end
      @read_bytes += data.bytesize
      raise self.class::InvalidArchive if data.bytesize > self.class::MAX_ENTRY_BYTES || @read_bytes > self.class::MAX_TOTAL_BYTES

      @entry_cache[entry.name] = data
    end

    # slideN.xml filenames do not necessarily reflect presentation order after
    # users reorder slides. Follow presentation.xml relationships first.
    def ordered_slide_paths
      presentation = xml_document("ppt/presentation.xml")
      if presentation
        relationships = relationships_for("ppt/presentation.xml")
        paths = presentation.xpath("//*[local-name()='sldId']").map do |slide_id|
          relationship = relationships[relationship_id(slide_id)]
          raise self.class::InvalidArchive unless relationship && relationship[:type].end_with?("/slide")

          relationship.fetch(:path)
        end
        return paths if paths.any?
      end

      @zip.glob("ppt/slides/slide*.xml")
        .sort_by do |entry|
          match = entry.name.match(%r{\Appt/slides/slide(\d+)\.xml\z})
          raise self.class::InvalidArchive unless match

          match[1].to_i
        end
        .map(&:name)
    end

    def presentation_slide_size
      presentation = xml_document("ppt/presentation.xml")
      size = presentation&.at_xpath("//*[local-name()='sldSz']")
      width = size&.[]("cx").to_i
      height = size&.[]("cy").to_i
      return self.class::DEFAULT_SLIDE_SIZE if width <= 0 || height <= 0

      [ width, height ]
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
      @xml_cache ||= {}
      return @xml_cache[path] if @xml_cache.key?(path)

      entry = @zip.find_entry(path)
      @xml_cache[path] = Nokogiri::XML(read_entry(entry)) { |config| config.strict.nonet } if entry
    end
  end
end

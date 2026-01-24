module Collavre
  class PptImporter
    # Import each slide from a PowerPoint file as HTML and create Creatives.
    def self.import(file, parent:, user:, create_root: false, filename: nil)
      require "zip"
      require "nokogiri"
      require "base64"
      require "pathname"
      require "erb"

      created = []
      root = parent
      if create_root
        title = filename ? File.basename(filename, File.extname(filename)) : "Presentation"
        root = Creative.create(user: user, parent: parent, description: ERB::Util.html_escape(title))
        created << root
      end

      Zip::File.open(file) do |zip|
        slide_entries = zip.glob("ppt/slides/slide*.xml").sort_by do |entry|
          entry.name[/slide(\d+)/, 1].to_i
        end

        slide_entries.each do |entry|
          slide_number = entry.name[/slide(\d+)/, 1]
          xml = Nokogiri::XML(entry.get_input_stream.read)
          ns = xml.collect_namespaces
          html_fragments = []

          # Extract paragraphs as HTML
          xml.xpath("//p:sp//a:p", ns).each do |p_node|
            text = p_node.xpath(".//a:t", ns).map(&:text).join
            next if text.strip.empty?
            html_fragments << "<p>#{ERB::Util.html_escape(text)}</p>"
          end

          # Map relationship IDs to targets for image lookup
          rels_name = "ppt/slides/_rels/slide#{slide_number}.xml.rels"
          relationships = {}
          if (rels_entry = zip.find_entry(rels_name))
            rel_xml = Nokogiri::XML(rels_entry.get_input_stream.read)
            rel_xml.xpath("//xmlns:Relationship").each do |rel|
              relationships[rel["Id"]] = rel["Target"]
            end
          end

          # Extract images and embed as base64 data URLs
          xml.xpath("//p:pic", ns).each do |pic|
            blip = pic.at_xpath(".//a:blip", ns)
            next unless blip
            embed_id = blip["r:embed"]
            target = relationships[embed_id]
            next unless target
            img_path = Pathname.new("ppt/slides").join(target).cleanpath.to_s
            img_entry = zip.find_entry(img_path)
            next unless img_entry
            data = img_entry.get_input_stream.read
            mime = case File.extname(img_path).downcase
            when ".png" then "image/png"
            when ".jpg", ".jpeg" then "image/jpeg"
            when ".gif" then "image/gif"
            else "application/octet-stream"
            end
            base64 = Base64.strict_encode64(data)
            html_fragments << "<img src=\"data:#{mime};base64,#{base64}\" />"
          end

          c = Creative.create(user: user, parent: root, description: html_fragments.join)
          created << c
        end
      end

      created
    end
  end
end

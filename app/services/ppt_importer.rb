class PptImporter
  def self.import(file, parent:, user:, create_root: false, filename: nil)
    require "zip"
    require "nokogiri"
    created = []
    root = parent
    if create_root
      title = filename ? File.basename(filename, File.extname(filename)) : "Presentation"
      root = Creative.create(user: user, parent: parent, description: title)
      created << root
    end
    Zip::File.open(file) do |zip|
      slide_entries = zip.glob("ppt/slides/slide*.xml").sort_by do |entry|
        entry.name.scan(/slide(\d+)/).flatten.first.to_i
      end
      slide_entries.each do |entry|
        xml = Nokogiri::XML(entry.get_input_stream.read)
        text = xml.xpath("//a:t").map(&:text).join('\n').strip
        c = Creative.create(user: user, parent: root, description: text)
        created << c
      end
    end
    created
  end
end

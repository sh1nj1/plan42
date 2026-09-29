module CollavreNotion
  class NotionPageContent
    def self.title(creative)
      Collavre::HtmlText.label(creative.effective_description).presence&.first(2000) || I18n.t("collavre_notion.modal.untitled")
    end

    def initialize(service, node)
      @service = service
      @node = node
    end

    def sync(creative)
      blocks = NotionCreativeExporter.new(creative).export_blocks
      title = self.class.title(creative)
      digest = Digest::SHA256.hexdigest([ title, blocks ].to_json)
      return if @node.content_hash == digest

      @service.update_page(@node.page_id, properties: { title: { title: [ { text: { content: title } } ] } })
      @node.update!(content_hash: nil)
      clear_owned_blocks
      append_content(blocks)
      @node.update!(content_hash: digest)
    end

    private

    # Tables contain up to 100 rows; send each separately to bound nested blocks.
    def append_content(blocks)
      blocks.slice_when { |left, right| left[:type] == "table" || right[:type] == "table" }.each do |group|
        group.each_slice(100) { |batch| append_batch(batch) }
      end
    end

    def clear_owned_blocks
      @node.body_block_ids.dup.each do |block_id|
        @service.delete_block(block_id)
        @node.update!(body_block_ids: @node.body_block_ids - [ block_id ])
      end
    end

    def append_batch(blocks)
      response = @service.append_blocks(@node.page_id, blocks)
      ids = response.fetch("results").map { |block| block.fetch("id") }
      @node.update!(body_block_ids: @node.body_block_ids + ids)
      raise NotionError, "Incomplete Notion block response" unless ids.size == blocks.size
    end
  end
end

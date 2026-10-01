module CollavreNotion
  # Each export owns an independent page mapping, including its root page.
  # Do not wrap remote writes in a DB transaction: completed pages must survive retries.
  class NotionTreeSync
    def initialize(service, account)
      @service = service
      @account = account
    end

    def call(creative, parent_page_id: nil, page_link: nil)
      @link = page_link || find_or_create_root(creative, parent_page_id)
      raise NotionError, "Invalid export link" unless @link.creative_id == creative.id && @link.notion_account_id == @account.id

      @root = creative
      visited = sync_tree(creative)
      archive_removed_pages(visited)
      remove_legacy_blocks
      @link.mark_synced!
      @link
    end

    private

    def find_or_create_root(creative, parent_id)
      links = @account.notion_page_links.where(creative: creative)
      existing = parent_id.present? ? links.find_by(parent_page_id: parent_id) : links.order(:id).first
      return existing if existing

      parent_id = parent_id.presence || @service.search_pages(page_size: 1).dig("results", 0, "id")
      raise NotionError, "No accessible pages found in workspace" unless parent_id

      title = NotionPageContent.title(creative)
      response = @service.create_page(parent_id: parent_id, title: title)
      links.create!(page_id: response.fetch("id"), page_url: response["url"], page_title: title, parent_page_id: parent_id)
    end

    def sync_tree(root)
      visited = []
      pending = [ [ root, @link.parent_page_id, @link.page_id ] ]
      until pending.empty?
        creative, parent_id, root_page_id = pending.pop
        node = find_or_create_node(creative, parent_id, root_page_id)
        sync_node(creative, node, parent_id)
        visited << creative.id
        creative.children.active.to_a.reverse_each do |child|
          pending << [ child, node.page_id, nil ]
        end
      end
      visited
    end

    def find_or_create_node(creative, parent_id, root_page_id)
      @link.notion_page_nodes.find_by(creative_id: creative.id) || begin
        page_id = root_page_id || @service.create_page(parent_id: parent_id, title: NotionPageContent.title(creative)).fetch("id")
        @link.notion_page_nodes.create!(creative_id: creative.id, page_id: page_id, parent_page_id: parent_id)
      end
    end

    def sync_node(creative, node, parent_id)
      page = @service.get_page(node.page_id)
      raise NotionNotFoundError if page["archived"] || page["in_trash"]

      sync_page(creative, node, parent_id)
    rescue NotionNotFoundError
      replace_missing_page(creative, node, parent_id)
      sync_page(creative, node, parent_id)
    end

    def replace_missing_page(creative, node, parent_id)
      title = NotionPageContent.title(creative)
      response = @service.create_page(parent_id: parent_id, title: title)
      node.transaction do
        if node.page_id == @link.page_id
          @link.update!(page_id: response.fetch("id"), page_url: response["url"], page_title: title)
        end
        node.update!(page_id: response.fetch("id"), parent_page_id: parent_id, body_block_ids: [], content_hash: nil)
      end
    end

    def sync_page(creative, node, parent_id)
      if node.parent_page_id != parent_id
        @service.move_page(node.page_id, parent_id: parent_id)
        node.update!(parent_page_id: parent_id)
      end
      NotionPageContent.new(@service, node).sync(creative)
      @link.update!(page_title: NotionPageContent.title(creative)) if node.page_id == @link.page_id
    end

    def archive_removed_pages(visited)
      nodes = @link.notion_page_nodes.where.not(creative_id: visited).to_a
      by_page = nodes.index_by(&:page_id)
      nodes.sort_by { |node| -page_depth(node, by_page) }.each do |node|
        next if active_in_tree?(node.creative_id)

        @service.archive_page(node.page_id)
        node.destroy!
      end
    end

    # Recheck live ancestry before destructive cleanup: source moves can race traversal.
    def active_in_tree?(creative_id)
      creative = Collavre::Creative.active.find_by(id: creative_id)
      return false unless creative

      ancestors = creative.self_and_ancestors.to_a
      ancestors.any? { |ancestor| ancestor.id == @root.id } && ancestors.all? { |ancestor| ancestor.archived_at.nil? }
    end

    def page_depth(node, by_page)
      depth = 0
      while (node = by_page[node.parent_page_id])
        depth += 1
      end
      depth
    end

    def remove_legacy_blocks
      @link.notion_block_links.order(:id).each do |block|
        @service.delete_block(block.block_id)
        block.destroy!
      end
    end
  end
end

require "digest"

class NotionService
  def initialize(user:)
    @user = user
    @account = user.notion_account
    raise NotionAuthError, "No Notion account found" unless @account
  end

  def client
    @client ||= NotionClient.new(@account)
  end

  def search_pages(query: nil, start_cursor: nil, page_size: 10)
    with_token_refresh { client.search_pages(query: query, start_cursor: start_cursor, page_size: page_size) }
  end

  def get_page(page_id)
    with_token_refresh { client.get_page(page_id) }
  end

  def create_page(parent_id:, title:, blocks: [])
    with_token_refresh { client.create_page(parent_id: parent_id, title: title, blocks: blocks) }
  end

  def update_page(page_id, properties: {}, blocks: nil)
    with_token_refresh { client.update_page(page_id, properties: properties, blocks: blocks) }
  end

  def get_page_blocks(page_id, start_cursor: nil, page_size: 100)
    with_token_refresh { client.get_page_blocks(page_id, start_cursor: start_cursor, page_size: page_size) }
  end

  def replace_page_blocks(page_id, blocks)
    with_token_refresh { client.replace_page_blocks(page_id, blocks) }
  end

  def append_blocks(parent_id, blocks)
    with_token_refresh { client.append_blocks(parent_id, blocks) }
  end

  def delete_block(block_id)
    with_token_refresh { client.delete_block(block_id) }
  end

  def get_workspace
    with_token_refresh { client.get_workspace }
  end

  # Create or update a page for a creative
  def sync_creative(creative, parent_page_id: nil)
    notion_link = find_or_create_page_link(creative, parent_page_id)

    if notion_link.page_id.present?
      # Update existing page
      update_creative_page(creative, notion_link)
    else
      # Create new page
      create_creative_page(creative, notion_link, parent_page_id)
    end

    notion_link.mark_synced!
    notion_link
  end

  private

  def with_token_refresh(&block)
    yield
  rescue NotionAuthError => e
    if refresh_token!
      @client = nil # Reset client with new token
      yield
    else
      raise e
    end
  end

  def refresh_token!
    # Notion uses OAuth 2.0 but doesn't issue refresh tokens in the same way as Google
    # For now, we'll just log the error and return false
    # In a production app, you'd implement proper token refresh logic here
    Rails.logger.error("Notion token refresh needed but not implemented")
    false
  end

  def find_or_create_page_link(creative, parent_page_id)
    @account.notion_page_links.find_or_initialize_by(creative: creative) do |link|
      link.parent_page_id = parent_page_id
    end
  end

  def create_creative_page(creative, notion_link, parent_page_id)
    title = creative.description.to_plain_text.strip.presence || "Untitled Creative"

    # Export only the children - the page title serves as the root creative
    children = creative.children.to_a
    Rails.logger.info("NotionService: Exporting creative #{creative.id} as page title with #{children.count} children as blocks")

    exporter = NotionCreativeExporter.new(creative)
    blocks = []

    # If no parent specified, search for a suitable workspace page
    parent_page_id ||= find_default_parent_page

    response = create_page(
      parent_id: parent_page_id,
      title: title,
      blocks: blocks
    )

    notion_link.update!(
      page_id: response["id"],
      page_title: title,
      page_url: response["url"],
      parent_page_id: parent_page_id
    )

    sync_child_blocks(notion_link, creative, children, exporter)

    response
  end

  def update_creative_page(creative, notion_link)
    title = creative.description.to_plain_text.strip.presence || "Untitled Creative"

    # Update with only the children - page title serves as the root creative
    children = creative.children.to_a
    Rails.logger.info("NotionService: Updating creative #{creative.id} as page title with #{children.count} children as blocks")

    exporter = NotionCreativeExporter.new(creative)

    properties = {
      title: {
        title: [ { text: { content: title } } ]
      }
    }

    update_page(notion_link.page_id, properties: properties)
    notion_link.update!(page_title: title)

    sync_child_blocks(notion_link, creative, children, exporter)
  end

  def find_default_parent_page
    # Search for pages in the workspace to find a suitable parent
    pages = search_pages(page_size: 1)
    pages.dig("results")&.first&.dig("id") || raise(NotionError, "No accessible pages found in workspace")
  end

  def sync_child_blocks(notion_link, creative, children, exporter)
    child_ids = children.map(&:id)
    existing_links = notion_link.notion_block_links.index_by(&:creative_id)

    if existing_links.empty?
      fetch_all_page_blocks(notion_link.page_id).each do |block|
        begin
          delete_block(block["id"])
        rescue NotionError => e
          Rails.logger.warn("NotionService: Failed to clear existing block #{block['id']} during initial sync: #{e.message}")
        end
      end
    end

    # Delete removed creatives
    (existing_links.keys - child_ids).each do |removed_id|
      link = existing_links[removed_id]
      begin
        delete_block(link.block_id)
      rescue NotionError => e
        Rails.logger.warn("NotionService: Failed to delete Notion block #{link.block_id} for creative #{removed_id}: #{e.message}")
      ensure
        link.destroy
      end
    end

    children.each do |child|
      exported_blocks = exporter.export_tree_blocks([ child ], 1, 0)
      next if exported_blocks.empty?

      content_hash = Digest::SHA256.hexdigest(exported_blocks.to_json)
      link = existing_links[child.id]

      next if link.present? && link.content_hash == content_hash

      if link.present?
        begin
          delete_block(link.block_id)
        rescue NotionError => e
          Rails.logger.warn("NotionService: Failed to delete stale Notion block #{link.block_id} for creative #{child.id}: #{e.message}")
        ensure
          link.destroy
        end
      end

      response = append_blocks(notion_link.page_id, exported_blocks)
      new_block_id = response.dig("results", 0, "id")
      if new_block_id.blank?
        Rails.logger.warn("NotionService: Unable to determine new block id for creative #{child.id}")
        next
      end

      link = notion_link.notion_block_links.create!(
        creative: child,
        block_id: new_block_id,
        content_hash: content_hash
      )
      existing_links[child.id] = link
    end
  end

  def fetch_all_page_blocks(page_id)
    blocks = []
    cursor = nil

    loop do
      response = get_page_blocks(page_id, start_cursor: cursor)
      blocks.concat(response.fetch("results", []))
      break unless response["has_more"]

      cursor = response["next_cursor"]
    end

    blocks
  end
end

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
    blocks = NotionCreativeExporter.new(creative).export_blocks

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

    response
  end

  def update_creative_page(creative, notion_link)
    title = creative.description.to_plain_text.strip.presence || "Untitled Creative"
    blocks = NotionCreativeExporter.new(creative).export_blocks

    properties = {
      title: {
        title: [ { text: { content: title } } ]
      }
    }

    update_page(notion_link.page_id, properties: properties, blocks: blocks)
    notion_link.update!(page_title: title)
  end

  def find_default_parent_page
    # Search for pages in the workspace to find a suitable parent
    pages = search_pages(page_size: 1)
    pages.dig("results")&.first&.dig("id") || raise(NotionError, "No accessible pages found in workspace")
  end
end

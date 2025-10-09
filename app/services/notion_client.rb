class NotionClient
  BASE_URL = "https://api.notion.com/v1"
  API_VERSION = "2022-06-28"

  def initialize(account)
    @account = account
    @token = account.token
  end

  def search_pages(query: nil, start_cursor: nil, page_size: 10)
    Rails.logger.info("NotionClient: Searching for pages with query: #{query}, page_size: #{page_size}")

    body = {
      filter: { property: "object", value: "page" },
      page_size: page_size
    }
    body[:query] = query if query.present?
    body[:start_cursor] = start_cursor if start_cursor.present?

    Rails.logger.info("NotionClient: Search request body: #{body.to_json}")
    result = post("search", body)
    Rails.logger.info("NotionClient: Search returned #{result["results"]&.length || 0} results")
    result
  end

  def get_page(page_id)
    get("pages/#{format_id(page_id)}")
  end

  def create_page(parent_id:, title:, blocks: [])
    Rails.logger.info("NotionClient: Creating page with #{blocks.length} blocks")

    # Notion limits page creation to 100 blocks, so create with minimal content first
    body = {
      parent: { page_id: parent_id },
      properties: {
        title: {
          title: [ { text: { content: title } } ]
        }
      },
      children: blocks.length > 100 ? [] : blocks
    }

    response = post("pages", body)

    # If we have more than 100 blocks, add them in batches after page creation
    if blocks.length > 100
      Rails.logger.info("NotionClient: Adding #{blocks.length} blocks in batches (100 per batch)")
      page_id = response["id"]
      Rails.logger.info("NotionClient: Created page ID: #{page_id}")

      # Give Notion a moment to fully create the page
      sleep(1)

      # Add blocks in batches of 100
      blocks.each_slice(100).with_index do |block_batch, index|
        Rails.logger.info("NotionClient: Adding batch #{index + 1} with #{block_batch.length} blocks")
        append_blocks(page_id, block_batch)
        Rails.logger.info("NotionClient: Successfully added batch #{index + 1}")
      end
    end

    response
  end

  def update_page(page_id, properties: {}, blocks: nil)
    body = { properties: properties }
    response = patch("pages/#{format_id(page_id)}", body)

    if blocks.present?
      replace_page_blocks(page_id, blocks)
    end

    response
  end

  def get_page_blocks(page_id, start_cursor: nil, page_size: 100)
    params = { page_size: page_size }
    params[:start_cursor] = start_cursor if start_cursor.present?

    get("blocks/#{format_id(page_id)}/children", params)
  end

  def replace_page_blocks(page_id, blocks)
    Rails.logger.info("NotionClient: Replacing page blocks with #{blocks.length} blocks")

    # First, get existing blocks
    existing_blocks = get_page_blocks(page_id)

    # Delete existing blocks
    existing_blocks.dig("results")&.each do |block|
      delete_block(block["id"])
    end

    # Add new blocks in batches of 100
    if blocks.any?
      blocks.each_slice(100).with_index do |block_batch, index|
        Rails.logger.info("NotionClient: Adding replacement batch #{index + 1} with #{block_batch.length} blocks")
        append_blocks(page_id, block_batch)
      end
    end
  end

  def append_blocks(page_id, blocks)
    # Notion also limits append operations to 100 blocks
    if blocks.length > 100
      Rails.logger.info("NotionClient: Appending #{blocks.length} blocks in batches")
      aggregated_results = []

      blocks.each_slice(100).with_index do |block_batch, index|
        Rails.logger.info("NotionClient: Appending batch #{index + 1} with #{block_batch.length} blocks")
        response = patch("blocks/#{format_id(page_id)}/children", { children: block_batch })

        if response.is_a?(Hash)
          batch_results = response.fetch("results", [])
          aggregated_results.concat(batch_results) if batch_results.any?
        end
      end

      aggregated_results.any? ? { "results" => aggregated_results } : nil
    else
      patch("blocks/#{format_id(page_id)}/children", { children: blocks })
    end
  end

  def delete_block(block_id)
    delete("blocks/#{format_id(block_id)}")
  end

  def get_workspace
    get("users/me")
  end

  private

  def get(path, params = {})
    url = "#{BASE_URL}/#{path}"
    url += "?#{params.to_query}" if params.any?

    response = HTTParty.get(
      url,
      headers: headers,
      timeout: 30
    )

    handle_response(response)
  end

  def post(path, body)
    response = HTTParty.post(
      "#{BASE_URL}/#{path}",
      headers: headers,
      body: body.to_json,
      timeout: 30
    )

    handle_response(response)
  end

  def patch(path, body)
    response = HTTParty.patch(
      "#{BASE_URL}/#{path}",
      headers: headers,
      body: body.to_json,
      timeout: 30
    )

    handle_response(response)
  end

  def delete(path)
    response = HTTParty.delete(
      "#{BASE_URL}/#{path}",
      headers: headers,
      timeout: 30
    )

    handle_response(response)
  end

  def headers
    {
      "Authorization" => "Bearer #{@token}",
      "Notion-Version" => API_VERSION,
      "Content-Type" => "application/json"
    }
  end

  def format_id(id)
    # Keep dashes in UUIDs - Notion API expects them
    id.to_s
  end

  def handle_response(response)
    Rails.logger.info("Notion API Response: #{response.code} for #{response.request.last_uri}")
    Rails.logger.debug("Notion API Response Body: #{response.body}")

    case response.code
    when 200, 201
      response.parsed_response
    when 400
      Rails.logger.error("Notion API 400 error: #{response.body}")
      raise NotionError, "Bad request: #{response.parsed_response}"
    when 401
      Rails.logger.error("Notion API 401 error: #{response.body}")
      raise NotionAuthError, "Unauthorized: Token may be expired"
    when 403
      Rails.logger.error("Notion API 403 error: #{response.body}")
      raise NotionError, "Forbidden: Insufficient permissions"
    when 404
      Rails.logger.error("Notion API 404 error: #{response.body}")
      raise NotionError, "Resource not found"
    when 429
      Rails.logger.error("Notion API 429 error: #{response.body}")
      raise NotionRateLimitError, "Rate limit exceeded"
    else
      Rails.logger.error("Notion API error: #{response.code} #{response.body}")
      raise NotionError, "API error: #{response.code}"
    end
  rescue HTTParty::Error, SocketError, Timeout::Error => e
    Rails.logger.error("Notion API connection error: #{e.message}")
    raise NotionConnectionError, "Connection failed: #{e.message}"
  end
end

class NotionError < StandardError; end
class NotionAuthError < NotionError; end
class NotionRateLimitError < NotionError; end
class NotionConnectionError < NotionError; end

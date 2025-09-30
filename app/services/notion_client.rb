class NotionClient
  BASE_URL = "https://api.notion.com/v1"
  API_VERSION = "2022-06-28"

  def initialize(account)
    @account = account
    @token = account.token
  end

  def search_pages(query: nil, start_cursor: nil, page_size: 10)
    body = {
      filter: { property: "object", value: "page" },
      page_size: page_size
    }
    body[:query] = query if query.present?
    body[:start_cursor] = start_cursor if start_cursor.present?

    post("search", body)
  end

  def get_page(page_id)
    get("pages/#{page_id}")
  end

  def create_page(parent_id:, title:, blocks: [])
    body = {
      parent: { page_id: parent_id },
      properties: {
        title: {
          title: [ { text: { content: title } } ]
        }
      },
      children: blocks
    }

    post("pages", body)
  end

  def update_page(page_id, properties: {}, blocks: nil)
    body = { properties: properties }
    response = patch("pages/#{page_id}", body)

    if blocks.present?
      replace_page_blocks(page_id, blocks)
    end

    response
  end

  def get_page_blocks(page_id, start_cursor: nil, page_size: 100)
    params = { page_size: page_size }
    params[:start_cursor] = start_cursor if start_cursor.present?

    get("blocks/#{page_id}/children", params)
  end

  def replace_page_blocks(page_id, blocks)
    # First, get existing blocks
    existing_blocks = get_page_blocks(page_id)

    # Delete existing blocks
    existing_blocks.dig("results")&.each do |block|
      delete_block(block["id"])
    end

    # Add new blocks
    append_blocks(page_id, blocks) if blocks.any?
  end

  def append_blocks(page_id, blocks)
    post("blocks/#{page_id}/children", { children: blocks })
  end

  def delete_block(block_id)
    delete("blocks/#{block_id}")
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

  def handle_response(response)
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

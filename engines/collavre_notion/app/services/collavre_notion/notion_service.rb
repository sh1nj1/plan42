module CollavreNotion
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
      with_rate_limit_retry { client.search_pages(query: query, start_cursor: start_cursor, page_size: page_size) }
    end

    def get_page(page_id)
      with_rate_limit_retry { client.get_page(page_id) }
    end

    def create_page(parent_id:, title:, blocks: [])
      with_rate_limit_retry { client.create_page(parent_id: parent_id, title: title, blocks: blocks) }
    end

    def update_page(page_id, properties: {}, blocks: nil)
      with_rate_limit_retry { client.update_page(page_id, properties: properties, blocks: blocks) }
    end

    def append_blocks(parent_id, blocks)
      with_rate_limit_retry { client.append_blocks(parent_id, blocks) }
    end

    def delete_block(block_id)
      with_rate_limit_retry { client.delete_block(block_id) }
    rescue NotionNotFoundError
      # An already missing owned block needs no further cleanup.
      nil
    end

    def sync_creative(creative, parent_page_id: nil, page_link: nil)
      NotionExportLock.synchronize(@account.id) do
        I18n.with_locale(@user.locale.presence || I18n.default_locale) do
          NotionTreeSync.new(self, @account).call(creative, parent_page_id: parent_page_id, page_link: page_link)
        end
      end
    end

    def move_page(page_id, parent_id:)
      with_rate_limit_retry { client.move_page(page_id, parent_id: parent_id) }
    end

    def archive_page(page_id)
      with_rate_limit_retry { client.archive_page(page_id) }
    rescue NotionNotFoundError
      # An already missing owned page needs no further cleanup.
      nil
    end

    private

    def with_rate_limit_retry
      attempts = 0
      begin
        yield
      rescue NotionRateLimitError => error
        attempts += 1
        raise if attempts > 5

        sleep(error.retry_after)
        retry
      end
    end
  end
end

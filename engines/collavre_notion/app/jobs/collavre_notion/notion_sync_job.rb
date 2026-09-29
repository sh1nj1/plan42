module CollavreNotion
  class NotionSyncJob < ApplicationJob
    queue_as :default
    retry_on NotionRateLimitError, wait: :polynomially_longer, attempts: 8

    def perform(creative, notion_account, page_id)
      service = CollavreNotion::NotionService.new(user: notion_account.user)

      begin
        # Find the existing link
        link = CollavreNotion::NotionPageLink.find_by(
          creative: creative,
          notion_account: notion_account,
          page_id: page_id
        )

        unless link
          Rails.logger.error("No Notion page link found for creative #{creative.id} and page #{page_id}")
          return
        end

        service.sync_creative(creative, page_link: link)

        Rails.logger.info("Successfully synced creative #{creative.id} to Notion page #{page_id}")
      rescue NotionError => e
        Rails.logger.error("Notion sync failed for creative #{creative.id}: #{e.message}")
        raise e
      rescue StandardError => e
        Rails.logger.error("Unexpected error during Notion sync for creative #{creative.id}: #{e.message}")
        raise e
      end
    end
  end
end

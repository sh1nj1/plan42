class NotionSyncJob < ApplicationJob
  queue_as :default

  def perform(creative, notion_account, page_id)
    service = NotionService.new(user: notion_account.user)

    begin
      # Find the existing link
      link = NotionPageLink.find_by(
        creative: creative,
        notion_account: notion_account,
        page_id: page_id
      )

      unless link
        Rails.logger.error("No Notion page link found for creative #{creative.id} and page #{page_id}")
        return
      end

      # Update the existing Notion page with entire tree
      title = creative.description.to_plain_text.strip.presence || "Untitled Creative"
      Rails.logger.info("NotionSyncJob: Syncing tree starting from creative #{creative.id} with #{creative.descendants.count} descendants")
      blocks = NotionCreativeExporter.new(creative).export_tree_blocks([creative])

      properties = {
        title: {
          title: [ { text: { content: title } } ]
        }
      }

      service.update_page(page_id, properties: properties, blocks: blocks)
      link.update!(page_title: title)
      link.mark_synced!

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

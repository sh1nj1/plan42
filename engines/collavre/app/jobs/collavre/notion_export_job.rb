module Collavre
class NotionExportJob < ApplicationJob
  queue_as :default

  def perform(creative, notion_account, parent_page_id = nil)
    service = NotionService.new(user: notion_account.user)

    begin
      # Export the creative tree to Notion
      link = service.sync_creative(creative, parent_page_id: parent_page_id)

      Rails.logger.info("Successfully exported creative #{creative.id} to Notion page #{link.page_id}")

      # You could add broadcast/notification logic here if needed
      # ActionCable.server.broadcast("user_#{notion_account.user.id}", {
      #   type: 'notion_export_complete',
      #   creative_id: creative.id,
      #   page_url: link.page_url
      # })

    rescue NotionError => e
      Rails.logger.error("Notion export failed for creative #{creative.id}: #{e.message}")
      raise e
    rescue StandardError => e
      Rails.logger.error("Unexpected error during Notion export for creative #{creative.id}: #{e.message}")
      raise e
    end
  end
end
end

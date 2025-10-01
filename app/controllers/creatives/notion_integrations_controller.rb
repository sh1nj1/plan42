module Creatives
  class NotionIntegrationsController < ApplicationController
    before_action :set_creative
    before_action :ensure_read_permission
    before_action :ensure_admin_permission, only: [ :show, :update ]

    def show
      account = Current.user.notion_account
      links = linked_page_links(account)

      Rails.logger.info("Notion Integration: Showing status for user #{Current.user.id}, connected: #{account.present?}")

      render json: {
        connected: account.present?,
        creative_title: @creative.description.to_plain_text.strip.presence || "Untitled Creative",
        account: account && {
          workspace_name: account.workspace_name,
          workspace_id: account.workspace_id,
          bot_id: account.bot_id
        },
        linked_pages: links.map do |link|
          {
            page_id: link.page_id,
            page_title: link.page_title,
            page_url: link.page_url,
            last_synced_at: link.last_synced_at
          }
        end,
        available_pages: account.present? ? fetch_available_pages(account) : []
      }
    end

    def update
      account = Current.user.notion_account
      unless account
        render json: { error: "not_connected" }, status: :unprocessable_entity
        return
      end

      Rails.logger.info("Notion Integration Update: Full params = #{params.to_unsafe_h}")

      integration_attributes = integration_params
      Rails.logger.info("Notion Integration Update: integration_params = #{integration_attributes}")

      action = integration_attributes[:action]
      parent_page_id = integration_attributes[:parent_page_id]

      Rails.logger.info("Notion Integration Update: action=#{action}, parent_page_id=#{parent_page_id}")

      begin
        case action
        when "export"
          # Export creative to Notion
          NotionExportJob.perform_later(@creative, account, parent_page_id)
          render json: { success: true, message: "Export started" }
        when "sync"
          # Sync existing page
          link = linked_page_links(account).first
          if link
            NotionSyncJob.perform_later(@creative, account, link.page_id)
            render json: { success: true, message: "Sync started" }
          else
            render json: { error: "no_linked_page" }, status: :unprocessable_entity
          end
        else
          render json: { error: "invalid_action" }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("Notion integration error: #{e.message}")
        render json: { error: "operation_failed", message: e.message }, status: :internal_server_error
      end
    end

    def destroy
      unless @creative.has_permission?(Current.user, :write)
        render json: { error: "forbidden" }, status: :forbidden
        return
      end

      account = Current.user.notion_account
      unless account
        render json: { error: "not_connected" }, status: :unprocessable_entity
        return
      end

      page_id = params[:page_id]

      if page_id
        # Remove specific page link
        link = linked_page_links(account).find_by(page_id: page_id)
        unless link
          render json: { error: "not_found" }, status: :not_found
          return
        end

        link.destroy!
      else
        # Remove all page links for this creative
        linked_page_links(account).destroy_all
      end

      links = linked_page_links(account)
      render json: {
        success: true,
        linked_pages: links.map do |link|
          {
            page_id: link.page_id,
            page_title: link.page_title,
            page_url: link.page_url,
            last_synced_at: link.last_synced_at
          }
        end
      }
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id])
    end

    def ensure_read_permission
      return if @creative.has_permission?(Current.user, :read)

      render json: { error: "forbidden" }, status: :forbidden
    end

    def ensure_admin_permission
      return if @creative.has_permission?(Current.user, :admin)

      render json: { error: "forbidden" }, status: :forbidden
    end

    def linked_page_links(account)
      return NotionPageLink.none unless account

      @creative.notion_page_links.where(notion_account: account)
    end

    def integration_params
      permitted_keys = [ :action, :parent_page_id, :page_id ]

      if params[:notion_integration].present?
        params.require(:notion_integration).permit(*permitted_keys)
      else
        params.permit(*permitted_keys)
      end
    end

    def fetch_available_pages(account)
      Rails.logger.info("Notion Integration: Fetching available pages for account #{account.id}")

      begin
        service = NotionService.new(user: account.user)
        pages_response = service.search_pages(page_size: 50)

        Rails.logger.info("Notion Integration: Search pages response - #{pages_response["results"]&.length || 0} pages found")

        pages = pages_response["results"]&.map do |page|
          {
            id: page["id"],
            title: extract_page_title(page),
            url: page["url"],
            parent: page["parent"]
          }
        end || []

        Rails.logger.info("Notion Integration: Returning #{pages.length} formatted pages")
        pages
      rescue => e
        Rails.logger.error("Notion Integration: Error fetching pages - #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        []
      end
    end

    def extract_page_title(page)
      # Handle different title property structures
      title_property = page.dig("properties", "title")

      if title_property && title_property["title"]
        title_property["title"].map { |t| t.dig("text", "content") }.compact.join("")
      elsif page["title"]
        page["title"].map { |t| t.dig("text", "content") }.compact.join("")
      else
        "Untitled"
      end
    end
  end
end

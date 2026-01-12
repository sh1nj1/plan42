module Admin
  class SettingsController < ApplicationController
    before_action :require_system_admin!

    def index
      @help_link = SystemSetting.find_by(key: "help_menu_link")&.value
      @mcp_tool_approval = SystemSetting.find_by(key: "mcp_tool_approval_required")&.value == "true"
    end

    def update
      begin
        SystemSetting.transaction do
          # Help Link
          help_link_setting = SystemSetting.find_or_initialize_by(key: "help_menu_link")
          help_link_setting.value = params[:help_link].to_s.strip
          help_link_setting.save!

          # MCP Tool Approval
          mcp_setting = SystemSetting.find_or_initialize_by(key: "mcp_tool_approval_required")
          mcp_setting.value = params[:mcp_tool_approval] == "1" ? "true" : "false"
          mcp_setting.save!
        end

        redirect_to admin_path, notice: t("admin.settings.updated")
      rescue ActiveRecord::RecordInvalid
        @help_link = params[:help_link]
        @mcp_tool_approval = params[:mcp_tool_approval] == "1"
        render :index, status: :unprocessable_entity
      end
    end
  end
end

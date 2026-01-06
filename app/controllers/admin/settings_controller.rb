module Admin
  class SettingsController < ApplicationController
    before_action :require_system_admin!

    def index
      @help_link = SystemSetting.find_by(key: "help_menu_link")&.value
    end

    def update
      setting = SystemSetting.find_or_initialize_by(key: "help_menu_link")
      setting.value = params[:help_link].to_s.strip

      if setting.save
        redirect_to admin_path, notice: t("admin.settings.updated")
      else
        @help_link = params[:help_link]
        render :index, status: :unprocessable_entity
      end
    end
  end
end

module Collavre
  class NotionAuthController < ApplicationController
    allow_unauthenticated_access only: :callback
    before_action -> { enforce_auth_provider!(:notion) }, only: :callback

    def callback
      auth = request.env["omniauth.auth"]
      notion = Collavre::NotionAccount.find_or_initialize_by(notion_uid: auth.uid)

      if notion.new_record?
        unless Current.user
          redirect_to new_session_path, alert: I18n.t("collavre.notion_auth.login_first")
          return
        end
        notion.user = Current.user
      end

      notion.token = auth.credentials.token
      notion.workspace_name = auth.info.name
      notion.workspace_icon = auth.extra.raw_info.workspace_icon
      notion.save!

      redirect_to collavre.creatives_path, notice: I18n.t("collavre.notion_auth.connected")
    end
  end
end

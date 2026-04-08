module CollavreNotion
  class NotionAuthController < ApplicationController
    allow_unauthenticated_access only: :callback
    before_action -> { enforce_auth_provider!(:notion) }, only: :callback

    def callback
      auth = request.env["omniauth.auth"]
      notion = CollavreNotion::NotionAccount.find_or_initialize_by(notion_uid: auth.uid)

      if notion.new_record?
        unless Current.user
          redirect_to collavre.new_session_path, alert: I18n.t("collavre_notion.notion_auth.login_first")
          return
        end
        notion.user = Current.user
      end

      notion.token = auth.credentials.token
      notion.workspace_name = auth.info.name
      notion.save!

      # If opened in popup, close it and notify parent window
      if params[:popup] || request.referer&.include?("popup=true") || session[:oauth_popup]
        session.delete(:oauth_popup)
        @fallback_path = collavre.creatives_path
        render template: "collavre_notion/notion_auth/callback_success", layout: false
      else
        redirect_to collavre.creatives_path, notice: I18n.t("collavre_notion.notion_auth.connected")
      end
    end
  end
end

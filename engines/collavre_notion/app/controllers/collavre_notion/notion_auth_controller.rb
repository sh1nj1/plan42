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
        render html: <<-HTML.html_safe
          <!DOCTYPE html>
          <html>
          <head><title>Notion Connected</title></head>
          <body>
            <script>
              if (window.opener) {
                window.opener.postMessage({ type: 'notion_oauth_success', connected: true }, '*');
                window.close();
              } else {
                window.location.href = '#{collavre.creatives_path}';
              }
            </script>
            <p>#{I18n.t("collavre_notion.notion_auth.connected")}</p>
            <p>This window should close automatically. If not, you can close it manually.</p>
          </body>
          </html>
        HTML
      else
        redirect_to collavre.creatives_path, notice: I18n.t("collavre_notion.notion_auth.connected")
      end
    end
  end
end

module Collavre
  module Concerns
    module Shareable
      extend ActiveSupport::Concern

      def request_permission
        creative = @creative.effective_origin
        if creative.user == Current.user || creative.has_permission?(Current.user, :write)
          return head :unprocessable_entity
        end

        # A requester who already has some access (read or feedback) is
        # specifically asking for a write upgrade — distinguish that from a
        # from-zero access request so the owner knows which one it is.
        already_has_read_access = creative.has_permission?(Current.user, :read)

        short_title = Collavre::HtmlText.markdown_label(creative.effective_origin.description, 10)
        creative_path = Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)
        creative_link = "[#{short_title}](#{creative_path})"

        inbox_creative = Creative.inbox_for(creative.user)
        system_topic = inbox_creative.system_topic(fallback_user: creative.user)
        i18n_key = already_has_read_access ? "inbox.write_permission_requested" : "inbox.permission_requested"
        msg = I18n.t(
          i18n_key,
          user: Current.user.display_name,
          short_title: creative_link,
          locale: creative.user.locale || "en"
        )
        Comment.create!(
          creative: inbox_creative,
          topic: system_topic,
          content: msg,
          user: nil,
          skip_default_user: true
        )

        head :ok
      end
    end
  end
end

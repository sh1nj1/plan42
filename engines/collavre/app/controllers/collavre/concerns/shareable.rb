module Collavre
  module Concerns
    module Shareable
      extend ActiveSupport::Concern

      def request_permission
        creative = @creative.effective_origin
        if creative.user == Current.user || creative.has_permission?(Current.user, :read)
          return head :unprocessable_entity
        end

        short_title = helpers.strip_tags(creative.effective_origin.description).truncate(10)
        creative_path = Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)
        creative_link = "[#{short_title}](#{creative_path})"

        inbox_creative = Creative.inbox_for(creative.user)
        system_topic = inbox_creative.system_topic(fallback_user: creative.user)
        msg = I18n.t(
          "inbox.permission_requested",
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

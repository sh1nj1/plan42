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

        InboxItem.create!(
          owner: creative.user,
          message_key: "inbox.permission_requested",
          message_params: { user: Current.user.display_name, short_title: short_title },
          link: creative_url(
            creative,
            Rails.application.config.action_mailer.default_url_options.merge(share_request: Current.user.email)
          )
        )

        head :ok
      end
    end
  end
end

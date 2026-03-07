module Collavre
  module Comments
    module Conversion
      extend ActiveSupport::Concern

      def convert
        unless can_convert_comment?
          render json: { error: I18n.t("collavre.comments.convert_not_allowed") }, status: :forbidden and return
        end

        created_creatives = ::MarkdownImporter.import(
          @comment.content,
          parent: @creative,
          user: @creative.user,
          create_root: true
        )

        primary_creative = created_creatives.first
        system_message = build_convert_system_message(primary_creative) if primary_creative

        @comment.destroy

        if system_message.present?
          Current.set(session: nil) do
            @creative.comments.create!(content: system_message, user: nil)
          end
        end

        head :no_content
      end

      private

      def can_convert_comment?
        @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
      end

      def build_convert_system_message(creative)
        title = helpers.strip_tags(creative.description).to_s.strip
        title = I18n.t("collavre.comments.convert_system_message_default_title") if title.blank?
        url = creative_path(creative)
        I18n.t("collavre.comments.convert_system_message", title: title, url: url)
      end
    end
  end
end

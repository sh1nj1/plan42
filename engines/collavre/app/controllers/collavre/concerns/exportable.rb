module Collavre
  module Concerns
    module Exportable
      extend ActiveSupport::Concern

      def export_markdown
        creatives = if params[:parent_id]
          parent_creative = Creative.find(params[:parent_id])
          effective_origin = parent_creative.effective_origin
          unless parent_creative.has_permission?(Current.user, :read) &&
                 effective_origin.has_permission?(Current.user, :read)
            render plain: t("collavre.creatives.errors.no_permission"), status: :forbidden and return
          end
          [ effective_origin ]
        else
          Creative.where(parent_id: nil).map(&:effective_origin).uniq.select do |creative|
            creative.has_permission?(Current.user, :read)
          end
        end

        if creatives.empty?
          render plain: t("collavre.creatives.errors.no_permission"), status: :forbidden and return
        end

        markdown = helpers.render_creative_tree_markdown(creatives)
        send_data markdown, filename: "creatives.md", type: "text/markdown"
      end
    end
  end
end

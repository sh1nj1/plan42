module Collavre
  module Concerns
    module SlideViewable
      extend ActiveSupport::Concern

      def slide_view
        unless @creative.has_permission?(Current.user, :read)
          if Current.user
            redirect_to creatives_path, alert: t("collavre.creatives.errors.no_permission")
          else
            request_authentication
          end
          return
        end

        @slide_ids = []
        @root_depth = @creative.ancestors.count
        build_slide_ids(@creative)
        render layout: "collavre/slide"
      end

      private

      def build_slide_ids(node)
        return unless node.has_permission?(Current.user, :read)

        @slide_ids << node.id
        children = node.children.order(:sequence)
        if node.origin_id.present?
          linked_children = node.linked_children
          children = (children + linked_children).uniq.sort_by(&:sequence)
        end
        children.each { |child| build_slide_ids(child) }
      end
    end
  end
end

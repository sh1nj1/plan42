module Collavre
  module CreativeRenderers
    class Menu
      def self.render(data)
        return "" if data.blank?

        label = data["label"].presence || data["path"]
        icon = data["icon"].presence
        path = data["path"].presence
        permissions = Array(data["permissions"])

        parts = []
        parts << icon if icon
        parts << label

        html = "<p>#{ERB::Util.html_escape(parts.join(" "))}</p>"

        meta_parts = []
        meta_parts << "<code>#{ERB::Util.html_escape(path)}</code>" if path
        meta_parts << permissions.map { |p| ERB::Util.html_escape(p) }.join(", ") if permissions.any?

        if meta_parts.any?
          html += "<p><small>#{meta_parts.join(" · ")}</small></p>"
        end

        html
      end
    end
  end
end

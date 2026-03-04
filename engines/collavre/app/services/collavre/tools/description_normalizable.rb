module Collavre
  module Tools
    module DescriptionNormalizable
      private

      def normalize_description(desc)
        return desc if desc.blank?
        stripped = desc.strip
        # If it already looks like HTML, return as-is
        return stripped if stripped.start_with?("<")
        # Otherwise wrap in <p> tags
        "<p>#{ERB::Util.html_escape(stripped)}</p>"
      end
    end
  end
end

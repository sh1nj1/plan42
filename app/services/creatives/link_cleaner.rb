module Creatives
  # Cleans up CreativeLink and VirtualCreativeHierarchy records
  # when a creative is being deleted. Must be called before destroy
  # to avoid FK constraint violations.
  class LinkCleaner
    def self.cleanup(creative)
      new(creative).cleanup
    end

    def initialize(creative)
      @creative = creative
    end

    def cleanup
      # Get all link IDs where this creative is parent or origin
      link_ids = CreativeLink
        .where(parent_id: @creative.id)
        .or(CreativeLink.where(origin_id: @creative.id))
        .pluck(:id)

      # Delete VirtualCreativeHierarchy records first (has FK to creative_links)
      VirtualCreativeHierarchy.where(creative_link_id: link_ids).delete_all if link_ids.any?
      VirtualCreativeHierarchy.where(ancestor_id: @creative.id).delete_all
      VirtualCreativeHierarchy.where(descendant_id: @creative.id).delete_all

      # Then delete CreativeLinks
      CreativeLink.where(parent_id: @creative.id).delete_all
      CreativeLink.where(origin_id: @creative.id).delete_all
    end
  end
end

module Collavre
module Creatives
  # Resolves the IDs that the persistent workspace tree can actually render for
  # the current creative. Shared origin paths are re-rooted through the user's
  # linked shell, and unreadable or archived ancestors are omitted.
  class WorkspacePathResolver
    def initialize(creative:, user:)
      @creative = creative
      @user = user
    end

    def call
      return [] unless creative

      return renderable_ids(local_path_ids) if creative.origin_id?

      origin_path = local_path_ids
      reveal = RevealPathResolver.new([ creative.id ], user: user).call[creative.id]
      return renderable_ids(origin_path) if reveal.blank?

      anchor_index = origin_path.rindex { |id| reveal.key?(id) }
      return renderable_ids(origin_path) unless anchor_index

      reveal.fetch(origin_path[anchor_index]) + renderable_ids(origin_path.drop(anchor_index + 1))
    end

    private

    attr_reader :creative, :user

    def local_path_ids
      creative.ancestors.reverse.pluck(:id) + [ creative.id ]
    end

    def renderable_ids(ids)
      return [] if ids.empty?

      readable = PermissionFilter.new(user: user).readable_ids(ids).to_set
      active = Creative.where(id: ids, archived_at: nil).pluck(:id).to_set
      ids.select { |id| readable.include?(id) && active.include?(id) }
    end
  end
end
end

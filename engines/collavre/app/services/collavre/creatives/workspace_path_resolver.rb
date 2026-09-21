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

      reveal_paths = origin_path.filter_map { |id| [ id, reveal.fetch(id) ] if reveal.key?(id) }
      renderable_reveal_ids = renderable_ids(reveal_paths.flat_map(&:last).uniq).to_set
      anchor = reveal_paths.reverse.find do |_id, path|
        path.all? { |id| renderable_reveal_ids.include?(id) }
      end
      return renderable_ids(origin_path) unless anchor

      anchor_id, reveal_path = anchor
      anchor_index = origin_path.index(anchor_id)
      reveal_path + renderable_ids(origin_path.drop(anchor_index + 1))
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

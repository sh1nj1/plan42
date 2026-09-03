# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetRevertService
      def initialize(change_set:, user:, resolutions: {})
        @change_set = change_set
        @user = user
        @resolutions = resolutions
      end

      def call
        all_changes = @change_set.creative_changes.order(position: :desc)
        changes = ChangeSetVisibility.new(user: @user).changes(all_changes)
        targets = changes.to_h { |change| [ change, change.before ] }
        ChangeSetApplyService.new(
          source: @change_set,
          user: @user,
          targets: targets,
          resolutions: @resolutions,
          complete: changes.size == all_changes.size
        ).call
      end
    end
  end
end

# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetRestoreService
      def initialize(change_set:, user:)
        @change_set = change_set
        @user = user
      end

      def call
        all_changes = @change_set.creative_changes.order(:position)
        changes = ChangeSetVisibility.new(user: @user).changes(all_changes)
        targets = changes.to_h { |change| [ change, change.after ] }
        ChangeSetApplyService.new(
          source: @change_set,
          user: @user,
          targets: targets,
          mode: :restore,
          complete: changes.size == all_changes.size
        ).call
      end
    end
  end
end

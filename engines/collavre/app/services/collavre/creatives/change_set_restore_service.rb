# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetRestoreService
      def initialize(change_set:, user:)
        @change_set = change_set
        @user = user
      end

      def call
        targets = @change_set.creative_changes.order(:position).to_h { |change| [ change, change.after ] }
        ChangeSetApplyService.new(
          source: @change_set,
          user: @user,
          targets: targets,
          mode: :restore
        ).call
      end
    end
  end
end

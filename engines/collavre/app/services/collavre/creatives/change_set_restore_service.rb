# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetRestoreService
      def initialize(change_set:, user:)
        @change_set = change_set
        @user = user
      end

      def call
        ChangeSetApplyService.new(
          source: @change_set,
          user: @user,
          mode: :restore
        ).call
      end
    end
  end
end

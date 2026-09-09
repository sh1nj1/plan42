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
        ChangeSetApplyService.new(
          source: @change_set,
          user: @user,
          resolutions: @resolutions
        ).call
      end
    end
  end
end

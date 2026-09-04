# frozen_string_literal: true

module Collavre
  module Creatives
    class DraftChangeSetRejectService
      def initialize(change_set:, user:, scope_creative:)
        @change_set = change_set
        @user = user
        @scope_creative = scope_creative
      end

      def call
        CreativeChangeSet.transaction do
          source = CreativeChangeSet.lock.find(@change_set.id)
          next result(:not_revertible) unless source.status == "draft"
          unless @scope_creative.has_permission?(@user, :write)
            next result(:skipped, skipped: [ @scope_creative.id ])
          end
          unless ChangeSetApplyService.new(source: source, user: @user, mode: :draft).fully_authorized?
            next result(:skipped, skipped: [ @scope_creative.id ])
          end

          source.update!(status: "rejected")
          result(:rejected, change_set: source)
        end
      end

      private

      def result(status, change_set: nil, skipped: [])
        ChangeSetApplyService::Result.new(
          status: status,
          change_set: change_set,
          conflicts: [],
          skipped: skipped
        )
      end
    end
  end
end

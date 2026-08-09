# frozen_string_literal: true

module Collavre
  module Creatives
    # Handles creative destruction with optional recursive child deletion.
    class DestroyService
      def initialize(creative:, user:, delete_with_children: false, onboarding_cleanup: false)
        @creative = creative
        @user = user
        @delete_with_children = delete_with_children
        @onboarding_cleanup = onboarding_cleanup
      end

      def call
        if @creative.onboarding_item? && !@onboarding_cleanup
          return false unless @creative.has_permission?(@user, :admin)

          return Collavre::Onboarding::CompletionService.call(
            user: @creative.user,
            session_id: @creative.onboarding_metadata["session_id"]
          )
        end

        onboarding_owner = @creative.user if @creative.onboarding_guide?

        if @delete_with_children || onboarding_owner
          destroy_descendants_recursively(@creative)
        else
          reparent_children
        end

        CreativeShare.where(creative: @creative).destroy_all
        destroy_result = @creative.destroy
        if @creative.destroyed? && onboarding_owner
          onboarding_owner.update!(onboarding_completed_at: Time.current)
        end
        destroy_result
      end

      private

      def reparent_children
        parent = @creative.parent
        @creative.children.each { |child| child.update(parent: parent) }
      end

      def destroy_descendants_recursively(creative)
        deletable_children = creative.children_with_permission(@user, :admin)
        deletable_children.each do |child|
          destroy_descendants_recursively(child)
          CreativeShare.where(creative: child).destroy_all
          child.destroy
        end
      end
    end
  end
end

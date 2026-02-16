# frozen_string_literal: true

module Collavre
  module Creatives
    # Handles creative destruction with optional recursive child deletion.
    class DestroyService
      def initialize(creative:, user:, delete_with_children: false)
        @creative = creative
        @user = user
        @delete_with_children = delete_with_children
      end

      def call
        if @delete_with_children
          destroy_descendants_recursively(@creative)
        else
          reparent_children
        end

        CreativeShare.where(creative: @creative).destroy_all
        @creative.destroy
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

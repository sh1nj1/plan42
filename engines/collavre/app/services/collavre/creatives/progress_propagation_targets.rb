# frozen_string_literal: true

module Collavre
  module Creatives
    class ProgressPropagationTargets
      def initialize(creative)
        @creative = creative
      end

      def call
        targets = []
        queue = [ @creative ]
        visited_ids = Set.new
        until queue.empty?
          source = queue.shift
          next if visited_ids.include?(source.id)

          visited_ids << source.id
          parents_for(source).each do |parent|
            next if visited_ids.include?(parent.id) || targets.any? { |target| target.id == parent.id }

            targets << parent
            queue << parent
          end
        end
        targets
      end

      private

      def parents_for(source)
        [ source.parent, *source.linked_creatives.includes(:parent).filter_map(&:parent) ].compact
      end
    end
  end
end

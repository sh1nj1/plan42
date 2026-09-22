# frozen_string_literal: true

module Collavre
  class Creative
    module TypeSelectable
      extend ActiveSupport::Concern

      included do
        attr_writer :creative_type
        attr_accessor :creative_type_placement
        validate :validate_creative_type, if: -> { instance_variable_defined?(:@creative_type) }
      end

      def creative_type
        data.is_a?(Hash) ? data.fetch("kind", "") : ""
      end

      private

      def validate_creative_type
        Creatives::TypeTransition.new(self, @creative_type, Current.user, placement: creative_type_placement).apply
      end
    end
  end
end

module Collavre
module Creatives
  module Filters
    class BaseFilter
      def initialize(params:, scope:)
        @params = params
        @scope = scope
      end

      def active?
        raise NotImplementedError
      end

      def match
        raise NotImplementedError
      end

      private

      attr_reader :params, :scope
    end
  end
end
end

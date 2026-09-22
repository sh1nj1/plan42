module Collavre
module Creatives
  module Filters
    class BaseFilter
      def initialize(params:, scope:, user: nil)
        @params = params
        @scope = scope
        @user = user
      end

      def active?
        raise NotImplementedError
      end

      def match
        raise NotImplementedError
      end

      private

      attr_reader :params, :scope, :user
    end
  end
end
end

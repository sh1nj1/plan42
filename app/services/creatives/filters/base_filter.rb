module Creatives
  module Filters
    class BaseFilter
      def initialize(user:, params:, scope:)
        @user = user
        @params = params
        @scope = scope
      end

      def active?
        raise NotImplementedError, "#{self.class}#active? must be implemented"
      end

      def match
        raise NotImplementedError, "#{self.class}#match must be implemented"
      end

      protected

      attr_reader :user, :params, :scope
    end
  end
end

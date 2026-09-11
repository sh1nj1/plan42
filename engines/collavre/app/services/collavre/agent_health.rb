# frozen_string_literal: true

module Collavre
  # Registry for optional, vendor-owned agent health checkers.
  #
  # A checker is observational only: registering or removing one changes the
  # status shown in the UI, never whether Collavre attempts an agent call.
  module AgentHealth
    Result = Struct.new(:status, :error, keyword_init: true)

    class << self
      def register(vendor, checker)
        normalized_vendor = normalize_vendor(vendor)
        raise ArgumentError, "vendor is required" if normalized_vendor.empty?
        raise ArgumentError, "checker must be instantiable" unless checker.respond_to?(:new)

        checkers[normalized_vendor] = checker
      end

      def unregister(vendor)
        checkers.delete(normalize_vendor(vendor))
      end

      def checker_for(vendor)
        checkers[normalize_vendor(vendor)]
      end

      def vendors
        checkers.keys.freeze
      end

      private

      def checkers
        @checkers ||= {}
      end

      def normalize_vendor(vendor)
        vendor.to_s.strip.downcase
      end
    end
  end
end

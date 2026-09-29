# frozen_string_literal: true

module Collavre
  module Kollavy
    module Identity
      class Conflict < StandardError; end

      def self.agent?(user)
        user&.persisted? && user.system_agent? && user.email == EMAIL
      end

      def self.for_seed
        user = Collavre.user_class.find_or_initialize_by(email: EMAIL)
        if user.persisted? && !agent?(user)
          raise Conflict, "Kollavy identity is occupied by a non-system account; resolve it manually before seeding"
        end
        if user.new_record?
          user.system_agent = true
          user.password = SecureRandom.hex(32)
        end
        user
      end
    end
  end
end

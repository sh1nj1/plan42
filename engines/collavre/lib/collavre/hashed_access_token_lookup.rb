# frozen_string_literal: true

require "digest"

module Collavre
  module HashedAccessTokenLookup
    PREFIX = "sha256$"

    class << self
      def encode(plaintext)
        "#{PREFIX}#{Digest::SHA256.hexdigest(plaintext.to_s)}"
      end
    end

    def by_token(plaintext)
      value = plaintext.to_s
      return if value.start_with?(PREFIX)

      super || find_by(token: HashedAccessTokenLookup.encode(value))
    end
  end
end

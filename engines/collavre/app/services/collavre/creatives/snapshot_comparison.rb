# frozen_string_literal: true

module Collavre
  module Creatives
    module SnapshotComparison
      def self.conflict?(creative, expected, ignore: [])
        current = History.snapshot(creative)
        # Legacy snapshots predate origin_id tracking; compare only known fields.
        current = current.except("origin_id") unless expected.key?("origin_id")
        current.except(*ignore) != expected.except(*ignore)
      end
    end
  end
end

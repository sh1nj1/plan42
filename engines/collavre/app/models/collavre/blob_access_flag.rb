# frozen_string_literal: true

module Collavre
  # Per-blob flags that grant or track public access (see the migration for why
  # they are not blob metadata). A missing row means both flags are off.
  class BlobAccessFlag < ApplicationRecord
    self.table_name = "blob_access_flags"

    FLAGS = %i[public_asset cdn_public].freeze

    # Writes one flag with a single atomic upsert that touches only that
    # column, so concurrent writers of the other flag (or of blob metadata)
    # can neither erase nor restore it.
    def self.write!(blob_id, flag, value)
      raise ArgumentError, "unknown flag #{flag}" unless FLAGS.include?(flag)

      upsert({ blob_id: blob_id, flag => value }, unique_by: :blob_id, update_only: [ flag ])
    end

    def self.set?(blob_id, flag)
      where(blob_id: blob_id, flag => true).exists?
    end
  end
end

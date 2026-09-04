# frozen_string_literal: true

module Collavre
  class PurgeUnreferencedBlobJob < ApplicationJob
    queue_as :default

    def perform(blob_id)
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      return unless blob
      return if ActiveStorage::Attachment.where(blob_id: blob.id).exists?

      signed_id = blob.signed_id
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%"
      return if Creative.where("description LIKE ?", pattern).exists?

      blob.purge
    end
  end
end

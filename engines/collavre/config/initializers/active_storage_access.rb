# frozen_string_literal: true

# Blob access hardening: authorize the stock ActiveStorage endpoints and evict
# publicly cached /public-assets copies when a blob is detached or purged.
# See Collavre::ActiveStorageAccess and Collavre::CdnInvalidation.

if defined?(Collavre::IntegrationSettings::Registry)
  Collavre::IntegrationSettings::Registry.instance
    .register(:cloudfront_distribution_id, category: "misc", sensitive: false, requires_restart: false)
end

Rails.application.config.to_prepare do
  Collavre::ActiveStorageAccess.install!
end

ActiveSupport.on_load(:active_storage_blob) do
  after_destroy_commit do
    Collavre::CdnInvalidation.invalidate_blob(self)
    Collavre::BlobAccessFlag.where(blob_id: id).delete_all
  end
end

ActiveSupport.on_load(:active_storage_attachment) do
  after_destroy_commit { Collavre::CdnInvalidation.invalidate_blob(ActiveStorage::Blob.find_by(id: blob_id)) }
end

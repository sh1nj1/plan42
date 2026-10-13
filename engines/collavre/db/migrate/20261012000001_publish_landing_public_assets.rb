# frozen_string_literal: true

# /public-assets now serves a blob publicly only when it is readable
# anonymously. The landing-page media are linked by URL from the landing locales
# and need not belong to a public creative, so publish them explicitly before
# the new rule takes effect. Blobs that do not exist here (dev/test databases,
# other deployments) are skipped.
class PublishLandingPublicAssets < ActiveRecord::Migration[8.0]
  def up
    Collavre::PublicAssetAllowlist.publish!(Collavre::PublicAssetAllowlist.landing_signed_ids)
  end

  def down
    # Leaving the flag in place keeps the landing page working after rollback.
  end
end

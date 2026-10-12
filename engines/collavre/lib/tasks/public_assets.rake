# frozen_string_literal: true

namespace :collavre do
  namespace :public_assets do
    desc "Serve blobs publicly from /public-assets. SIGNED_IDS=id1,id2"
    task publish: :environment do
      blobs = Collavre::PublicAssetAllowlist.publish!(ENV.fetch("SIGNED_IDS", "").split(","))
      puts "Published #{blobs.size} blob(s): #{blobs.map(&:id).join(', ')}"
    end

    desc "Stop serving blobs publicly and invalidate the CDN copy. SIGNED_IDS=id1,id2"
    task unpublish: :environment do
      blobs = Collavre::PublicAssetAllowlist.unpublish!(ENV.fetch("SIGNED_IDS", "").split(","))
      puts "Unpublished #{blobs.size} blob(s): #{blobs.map(&:id).join(', ')}"
    end

    desc "Publish the /public-assets media referenced by the landing page locales"
    task publish_landing: :environment do
      signed_ids = Collavre::PublicAssetAllowlist.landing_signed_ids
      blobs = Collavre::PublicAssetAllowlist.publish!(signed_ids)
      puts "Published #{blobs.size} of #{signed_ids.size} landing blob(s)"
    end
  end
end

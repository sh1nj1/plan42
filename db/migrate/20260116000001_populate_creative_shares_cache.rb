class PopulateCreativeSharesCache < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Populating creative_shares_cache" do
      # Ensure the service is available before running
      unless defined?(Creatives::PermissionCacheBuilder)
        Rails.logger.warn "PermissionCacheBuilder not available, skipping cache population"
        return 0
      end

      count = 0
      # Include all shares including no_access (needed to override public shares)
      CreativeShare.find_each do |share|
        Creatives::PermissionCacheBuilder.propagate_share(share)
        count += 1
      end
      count
    end
  end

  def down
    execute "DELETE FROM creative_shares_caches"
  end
end

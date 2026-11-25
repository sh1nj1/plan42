require Rails.root.join("engines/collavre/db/migrate/20260922000002_deduplicate_root_creative_preferences")

module LegacyRootPreferences
  extend ActiveSupport::Concern

  included do
    teardown do
      if @legacy_root_preferences
        ActiveRecord::Migration.suppress_messages { DeduplicateRootCreativePreferences.new.up }
        Collavre::UserCreativePreference.connection.schema_cache.clear!
      end
    end
  end

  def allow_legacy_root_duplicates!
    @legacy_root_preferences = true
    ActiveRecord::Migration.suppress_messages { DeduplicateRootCreativePreferences.new.down }
    Collavre::UserCreativePreference.connection.schema_cache.clear!
  end
end

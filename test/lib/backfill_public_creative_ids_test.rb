require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20261008010000_backfill_public_creative_ids")

class BackfillPublicCreativeIdsTest < ActiveSupport::TestCase
  test "backfill assigns legacy IDs and preserves existing addresses on rerun" do
    legacy = Collavre::Creative.create!(user: users(:one), description: "Legacy")
    existing = Collavre::Creative.create!(user: users(:one), description: "Existing", public_id: "stable1234")
    perform_enqueued_jobs { Collavre::CreativeShare.create!(creative: legacy, user: nil, permission: :read) }
    Collavre::Creative.where(id: legacy.id).update_all(public_id: nil)
    migration = BackfillPublicCreativeIds.new
    migration.up
    identifier = legacy.reload.public_id
    assert_match(/\A[0-9A-Za-z]{10}\z/, identifier)
    migration.up
    migration.down
    assert_equal identifier, legacy.reload.public_id
    assert_equal "stable1234", existing.reload.public_id
  end
end

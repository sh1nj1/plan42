require "test_helper"
require_relative "../../db/migrate/20261008010000_backfill_public_creative_ids"

module Collavre
  class BackfillPublicCreativeIdsTest < ActiveSupport::TestCase
    test "backfill assigns missing addresses only to explicitly public creatives" do
      owner = users(:one)
      root = Creative.create!(user: owner, description: "Root")
      private_root = Creative.create!(user: owner, description: "Private")
      child = Creative.create!(user: owner, parent: root, description: "Child")
      linked = Creative.create!(user: owner, origin: root)
      archived = Creative.create!(user: owner, description: "Archived", archived_at: Time.current)
      denied = Creative.create!(user: owner, description: "Denied")
      existing = Creative.create!(user: owner, description: "Existing")
      perform_enqueued_jobs do
        [ root, child, linked, archived, existing ].each do |creative|
          CreativeShare.create!(creative: creative, user: nil, permission: :read)
        end
        CreativeShare.create!(creative: denied, user: nil, permission: :no_access)
        CreativeShare.create!(creative: private_root, user: users(:two), permission: :read)
      end
      records = [ root, private_root, child, linked, archived, denied ]
      Creative.where(id: records.map(&:id)).update_all(public_id: nil)
      token = existing.reload.public_id

      migration = BackfillPublicCreativeIds.new
      migration.up

      [ root, child, linked, archived ].each do |creative|
        assert_match(/\A[0-9A-Za-z]{10}\z/, creative.reload.public_id)
      end
      [ private_root, denied ].each { |creative| assert_nil creative.reload.public_id }
      assert_equal token, existing.reload.public_id
      root_token = root.public_id
      migration.up
      migration.down
      assert_equal root_token, root.reload.public_id
    end

    test "legacy public creatives retain addresses when becoming active roots" do
      parent = Creative.create!(user: users(:one), description: "Private parent")
      child = Creative.create!(user: users(:one), parent: parent, description: "Child")
      archived = Creative.create!(user: users(:one), description: "Archived", archived_at: Time.current)
      perform_enqueued_jobs do
        [ child, archived ].each { |creative| CreativeShare.create!(creative: creative, user: nil, permission: :read) }
      end
      Creative.where(id: [ child.id, archived.id ]).update_all(public_id: nil)

      BackfillPublicCreativeIds.new.up
      tokens = [ child, archived ].map { |creative| creative.reload.public_id }
      tokens.each { |token| assert_match(/\A[0-9A-Za-z]{10}\z/, token) }

      perform_enqueued_jobs do
        child.update!(parent: nil)
        archived.update!(archived_at: nil)
      end

      candidates = SeoController.new.send(:published_creatives)
      [ child, archived ].each_with_index do |creative, index|
        assert candidates.exists?(creative.id)
        assert creative.reload.publicly_readable?
        assert_equal tokens[index], creative.public_id
      end
    end
  end
end

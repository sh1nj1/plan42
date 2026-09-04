# frozen_string_literal: true

require "test_helper"

class CreativeHistoryPruneJobTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
    @first = Creative.create!(user: @user, description: "First history target")
    @second = Creative.create!(user: @user, description: "Second history target")
    Collavre::CreativeChange.delete_all
    Collavre::CreativeChangeSet.delete_all
  end

  test "keeps the configured recent count per Creative and prunes older sets" do
    sets = 12.times.map { |index| create_change_set(creatives: [ @first ], created_at: (120 + index).days.ago) }

    assert_equal 2, perform_with_retention(count: 10, days: 7)
    assert_equal sets.first(10).map(&:id).sort, Collavre::CreativeChangeSet.pluck(:id).sort
  end

  test "keeps changes inside the retention period even beyond the count" do
    sets = 12.times.map { |index| create_change_set(creatives: [ @first ], created_at: (index + 1).hours.ago) }

    assert_equal 0, perform_with_retention(count: 10, days: 7)
    assert_equal sets.map(&:id).sort, Collavre::CreativeChangeSet.pluck(:id).sort
  end

  test "starts the retention period when an older draft was applied" do
    recently_applied = create_change_set(creatives: [ @first ], created_at: 200.days.ago)
    recently_applied.update!(applied_at: 1.day.ago)
    10.times { |index| create_change_set(creatives: [ @first ], created_at: (100 + index).days.ago) }

    assert_equal 0, perform_with_retention(count: 10, days: 7)
    assert Collavre::CreativeChangeSet.exists?(recently_applied.id)
  end

  test "keeps a multi-Creative set when it is recent for any touched Creative" do
    shared = create_change_set(creatives: [ @first, @second ], created_at: 200.days.ago)
    10.times { |index| create_change_set(creatives: [ @first ], created_at: (100 + index).days.ago) }

    assert_equal 0, perform_with_retention(count: 10, days: 7)
    assert Collavre::CreativeChangeSet.exists?(shared.id)
  end

  test "never prunes drafts, reverts, referenced sets, or non-applied audit rows" do
    referenced = create_change_set(creatives: [ @first ], created_at: 300.days.ago)
    draft = create_change_set(creatives: [ @first ], created_at: 299.days.ago, status: "draft")
    rejected = create_change_set(creatives: [ @first ], created_at: 298.days.ago, status: "rejected")
    reverted = create_change_set(creatives: [ @first ], created_at: 297.days.ago, status: "reverted")
    revert = create_change_set(
      creatives: [ @first ],
      created_at: 296.days.ago,
      origin: "revert",
      reverts: referenced
    )
    10.times { |index| create_change_set(creatives: [ @first ], created_at: (100 + index).days.ago) }

    assert_equal 0, perform_with_retention(count: 10, days: 7)
    assert Collavre::CreativeChangeSet.exists?(referenced.id)
    assert Collavre::CreativeChangeSet.exists?(draft.id)
    assert Collavre::CreativeChangeSet.exists?(rejected.id)
    assert Collavre::CreativeChangeSet.exists?(reverted.id)
    assert Collavre::CreativeChangeSet.exists?(revert.id)
  end

  test "rechecks blobs retained only by pruned snapshots" do
    prunable = create_change_set(creatives: [ @first ], created_at: 200.days.ago)
    10.times { |index| create_change_set(creatives: [ @first ], created_at: (100 + index).days.ago) }
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("retained history file"),
      filename: "history.txt",
      content_type: "text/plain"
    )
    prunable.creative_changes.sole.history_file_attachments.create!(name: "history_files", blob: blob)
    callbacks = []

    ActiveRecord.stub(:after_all_transactions_commit, ->(&callback) { callbacks << callback }) do
      assert_equal 1, perform_with_retention(count: 10, days: 7)
    end

    assert_empty ActiveStorage::Attachment.where(blob: blob)
    scheduled_blob_ids = []
    Collavre::PurgeUnreferencedBlobJob.stub(:perform_later, ->(blob_id) { scheduled_blob_ids << blob_id }) do
      callbacks.sole.call
    end
    assert_equal [ blob.id ], scheduled_blob_ids
  end

  test "revalidates a materialized candidate after locking it" do
    candidate = create_change_set(creatives: [ @first ], created_at: 200.days.ago)
    10.times { |index| create_change_set(creatives: [ @first ], created_at: (100 + index).days.ago) }
    stale_candidates = Struct.new(:candidate) do
      def find_each
        yield candidate
      end
    end.new(candidate)
    create_change_set(creatives: [ @second ], created_at: 1.day.ago, origin: "revert", reverts: candidate)

    job = Collavre::CreativeHistoryPruneJob.new
    job.stub(:prunable_change_sets, stale_candidates) do
      assert_equal 0, job.perform
    end

    assert Collavre::CreativeChangeSet.exists?(candidate.id)
  end

  test "is scheduled daily in every queue environment" do
    schedules = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    %w[production desktop development].each do |environment|
      task = schedules.fetch(environment).fetch("creative_history_prune")
      assert_equal "Collavre::CreativeHistoryPruneJob", task.fetch("class")
      assert_equal "default", task.fetch("queue")
      assert_equal "at 4:30am every day", task.fetch("schedule")
    end
  end

  private

  def perform_with_retention(count:, days:)
    SystemSetting.stub(:creative_history_retention_count, count) do
      SystemSetting.stub(:creative_history_retention_days, days) do
        Collavre::CreativeHistoryPruneJob.perform_now
      end
    end
  end

  def create_change_set(creatives:, created_at:, status: "applied", origin: "editor", reverts: nil)
    change_set = Collavre::CreativeChangeSet.create!(
      actor_kind: "human",
      origin: origin,
      status: status,
      user: @user,
      reverts: reverts,
      created_at: created_at,
      updated_at: created_at
    )
    creatives.each_with_index do |creative, position|
      Collavre::CreativeChange.create!(
        change_set: change_set,
        creative: creative,
        operation: "update",
        before: { "progress" => 0.0 },
        after: { "progress" => 1.0 },
        position: position,
        created_at: created_at,
        updated_at: created_at
      )
    end
    change_set
  end
end

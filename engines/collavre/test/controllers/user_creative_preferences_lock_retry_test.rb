require "test_helper"

# with_preference reacquires the row when a concurrent collapse deletes it
# between the lookup and the lock. The retry has to stay bounded, and it must
# not cover the caller's block: a block that raises RecordNotFound itself
# would otherwise be replayed together with its side effects.
class UserCreativePreferencesLockRetryTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    Collavre::Current.user = @user
    @controller = Collavre::UserCreativePreferencesController.new
  end

  teardown do
    Collavre::Current.reset
  end

  test "retries the lookup when the row disappears before the lock" do
    lookups = 0
    stub_preference_for do
      lookups += 1
      raise ActiveRecord::RecordNotFound if lookups == 1

      real_preference
    end

    result = @controller.send(:with_preference, @creative.id) { |record| record.creative_id }

    assert_equal 2, lookups
    assert_equal @creative.id, result
  end

  test "stops retrying at the attempt limit instead of spinning" do
    lookups = 0
    stub_preference_for do
      lookups += 1
      raise ActiveRecord::RecordNotFound
    end

    assert_raises(ActiveRecord::RecordNotFound) do
      @controller.send(:with_preference, @creative.id) { |record| record }
    end

    assert_equal Collavre::UserCreativePreferencesController::MAX_PREFERENCE_LOCK_ATTEMPTS, lookups
  end

  test "does not replay the block when the block itself raises RecordNotFound" do
    lookups = 0
    stub_preference_for do
      lookups += 1
      real_preference
    end

    runs = 0
    assert_raises(ActiveRecord::RecordNotFound) do
      @controller.send(:with_preference, @creative.id) do
        runs += 1
        raise ActiveRecord::RecordNotFound
      end
    end

    assert_equal 1, lookups
    assert_equal 1, runs
  end

  test "root insert conflict rolls back its savepoint and applies the toggle to the winner" do
    preference = Collavre::UserCreativePreference
    winner = preference.create!(user: @user, expanded_status: { "existing" => true })
    insert = preference.method(:insert_all!)
    attempts = 0
    # Simulate the lookup missing a concurrent winner, then raise a real
    # database constraint error inside the controller's insertion savepoint.
    preference.stub(:exists?, false) do
      preference.stub(:insert_all, lambda { |attributes|
        attempts += 1
        insert.call(attributes)
      }) do
        @controller.send(:with_expansion_order) do |order|
          order.issue
          @controller.send(:with_preference, nil) do |record|
            assert_equal winner.id, record.id
            record.set_expanded("new", true)
            record.save!
          end
        end
      end
    end

    assert_equal 1, attempts
    assert_equal({ "existing" => true, "new" => true }, winner.reload.expanded_status)
    assert_equal 1, preference.where(user: @user, creative_id: nil).count
    assert_not_empty @user.reload.expansion_save_sequences
  end

  test "non-root insertion uniqueness errors propagate" do
    Collavre::UserCreativePreference.stub(:insert_all, ->(*) { raise ActiveRecord::RecordNotUnique }) do
      assert_raises(ActiveRecord::RecordNotUnique) do
        @controller.send(:with_preference, @creative.id) { flunk "must not apply a failed insert" }
      end
    end
  end

  private

  def stub_preference_for(&block)
    @controller.define_singleton_method(:preference_for) { |_creative_id| block.call }
  end

  # An empty expanded_status fails validation, so seed the row the way the
  # controller does — through the unique preference key.
  def real_preference
    now = Time.current
    Collavre::UserCreativePreference.insert_all([
      { creative_id: @creative.id, user_id: @user.id, expanded_status: {}, created_at: now, updated_at: now }
    ], unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
    Collavre::UserCreativePreference.find_by!(creative_id: @creative.id, user_id: @user.id)
  end
end

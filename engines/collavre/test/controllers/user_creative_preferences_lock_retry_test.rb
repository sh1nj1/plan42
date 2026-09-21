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

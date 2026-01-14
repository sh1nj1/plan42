require "test_helper"

module Tools
  class CreativeRetrievalServiceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @parent = Creative.create!(user: @user, description: "Parent Creative")
      @child = Creative.create!(user: @user, parent: @parent, description: "Child Creative")

      # Setup another user who has permission on the parent
      @other_user = users(:two)
      CreativeShare.create!(user: @other_user, creative: @parent, permission: :read)
    end

    test "retrieves children when user has permission on parent" do
      # Simulate the other user context
      Current.set(user: @other_user) do
        service = Tools::CreativeRetrievalService.new

        # Call with parent ID
        results = service.call(id: @parent.id, level: 2)

        assert_not_empty results, "Should return results"
        parent_result = results.first

        assert_equal @parent.id, parent_result[:id], "Should return parent details"
        assert_not_empty parent_result[:children], "Should include children"

        child_result = parent_result[:children].first
        assert_equal @child.id, child_result[:id], "Child ID should match"
      end
    end

    test "clears permission cache before execution" do
      # Pre-populate cache with something that would cause failure if not cleared or reused incorrectly
      # In this test we just ensure it runs without error even if cache was dirty
      Current.creative_share_cache = { @parent.id => "dirty" }

      Current.set(user: @other_user) do
        service = Tools::CreativeRetrievalService.new
        results = service.call(id: @parent.id)

        assert_not_empty results
        # After call, the cache might be repopulated with correct data or nil depending on implementation details
        # The key is that it didn't crash or return wrong data due to "dirty"
        assert_equal @parent.id, results.first[:id]
      end
    end

    test "retrieves data when origin secret is enforced" do
      with_env("ORIGIN_SHARED_SECRET" => "test_secret") do
        Current.set(user: @other_user) do
          service = Tools::CreativeRetrievalService.new

          # This should not raise an error and return results
          # If the secret header wasn't sent, this would fail authentication in ApplicationController (mocked)
          results = service.call(id: @parent.id)

          assert_not_empty results
          assert_equal @parent.id, results.first[:id]
        end
      end
    end

    private

    def with_env(env)
      original_env = ENV.to_hash
      env.each { |k, v| ENV[k] = v }
      yield
    ensure
      ENV.replace(original_env)
    end
  end
end

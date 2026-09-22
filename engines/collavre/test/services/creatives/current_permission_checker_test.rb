require "test_helper"

module Collavre
  module Creatives
    class CurrentPermissionCheckerTest < ActiveSupport::TestCase
      setup do
        @previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        @owner = users(:one)
        @agent = users(:ai_bot)
        @root = Creative.create!(user: @owner, description: "Permission root")
        @child = Creative.create!(user: @owner, parent: @root, description: "Permission child")
      end

      teardown do
        ActiveJob::Base.queue_adapter = @previous_adapter
      end

      test "owner access and effective origin use current rows" do
        assert allowed?(@child, @owner)
        shell = Creative.create!(user: @agent, origin: @child, description: "Linked shell")
        assert allowed?(shell, @owner)
        assert_not allowed?(shell)
        share(@child, @agent, :feedback)
        assert allowed?(shell)
        @child.update!(user: users(:two))
        assert_not allowed?(shell, @owner)
        assert_not PermissionChecker.current_allowed?(-1, @agent, :feedback)
      end

      test "nearest user share overrides public even when below the threshold" do
        share(@root, nil, :admin)
        inherited = share(@root, @agent, :read)
        assert_not allowed?, "An inherited user entry overrides a more permissive public entry"
        direct = share(@child, @agent, :feedback)
        assert allowed?
        direct.update!(permission: :no_access)
        assert_not allowed?
        direct.destroy!
        assert_not allowed?, "Deleting the closer share restores the inherited restriction"
        inherited.destroy!
        assert allowed?, "Public is considered only when no user share remains"
      end

      test "closest public share and anonymous checks follow the hierarchy" do
        inherited = share(@root, nil, :feedback)
        assert allowed?(@child, nil)
        direct = share(@child, nil, :read)
        assert_not allowed?(@child, nil)
        direct.destroy!
        assert allowed?(@child, nil)
        inherited.destroy!
        assert_not allowed?(@child, nil)
      end

      %i[read no_access removed reassigned relocated].each do |change|
        test "reads #{change} inherited share before its permission cache job runs" do
          inherited = nil
          perform_enqueued_jobs(only: PermissionCacheJob) { inherited = share(@root, @agent, :feedback) }
          assert @child.has_permission?(@agent, :feedback)
          case change
          when :read, :no_access then inherited.update!(permission: change)
          when :removed then inherited.destroy!
          when :reassigned then inherited.update!(user: users(:two))
          when :relocated
            inherited.update!(creative: Creative.create!(user: @owner, description: "Elsewhere"))
          end

          assert @child.has_permission?(@agent, :feedback), "The asynchronous cache must still be stale"
          assert_not allowed?
        end
      end

      test "a moved creative reads its current ancestors before cache rebuilding" do
        perform_enqueued_jobs(only: PermissionCacheJob) { share(@root, @agent, :feedback) }
        assert allowed?
        @child.update!(parent: Creative.create!(user: @owner, description: "Private tree"))
        assert @child.has_permission?(@agent, :feedback)
        assert_not allowed?
      end

      test "authoritative checks never reuse a warmed worker SQL cache or query the permission table" do
        share(@root, @agent, :feedback)
        Creative.cache do
          assert allowed?
          queries = []
          capture = ->(*args) { queries << args.last if args.last[:sql].start_with?("SELECT") }
          ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { assert allowed? }
          assert queries.any?
          assert queries.none? { |query| query[:cached] }, "SQL cache may predate a committed revocation"
          assert queries.none? { |query| query[:sql].include?("creative_shares_caches") }
        end
      end

      private

      def share(creative, user, permission)
        CreativeShare.create!(creative: creative, user: user, permission: permission)
      end

      def allowed?(creative = @child, user = @agent)
        PermissionChecker.current_allowed?(creative.id, user, :feedback)
      end
    end
  end
end

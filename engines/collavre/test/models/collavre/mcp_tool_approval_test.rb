# frozen_string_literal: true

require "test_helper"

module Collavre
  class McpToolApprovalTest < ActiveSupport::TestCase
    # Each thread uses its own connection, like approvals on two server
    # processes, so rows must really commit.
    self.use_transactional_tests = false

    setup do
      @creative = Creative.create!(user: users(:one), description: "Approval lock")
      @earlier = McpTool.create!(creative: @creative, name: "lock_probe_a", source_code: source("lock_probe_a"))
      @later = McpTool.create!(creative: @creative, name: "lock_probe_b", source_code: source("lock_probe_b"))
    end

    teardown do
      McpTool.where(creative: @creative).destroy_all
      @creative&.destroy!
      ::Tools.send(:remove_const, :LockProbeService) if ::Tools.const_defined?(:LockProbeService, false)
    end

    test "an approval waits for another process's approval and then sees its constants" do
      started = Queue.new
      gate = Queue.new
      other_worker = Thread.new do
        McpTool.serialize_approvals do
          @earlier.update!(approved_at: Time.current)
          started << true
          gate.pop
        end
      end
      started.pop

      approval = Thread.new { @later.approve! rescue $! }
      assert_nil approval.join(0.5), "the approval must wait for the in-flight one to commit"
      gate << true
      other_worker.join

      assert_match(/uses Tools::LockProbeService, which another approved tool already uses/, approval.value.message)
      assert_not @later.reload.active?
      assert_not ::Tools.const_defined?(:LockProbeService, false), "the refused source is never evaluated"
    ensure
      gate << true if other_worker&.alive?
      [ other_worker, approval ].compact.each { |t| t.join(5) }
    end

    test "an approval whose record cannot be saved unregisters the tool" do
      @later.define_singleton_method(:update!) { |*| raise ActiveRecord::RecordInvalid, self }

      assert_raises(ActiveRecord::RecordInvalid) { @later.approve! }
      assert_not @later.reload.active?
      assert_nil ::Tools::MetaToolService.new.find_schema("lock_probe_b")
      assert_not ::Tools.const_defined?(:LockProbeService, false)
    end

    test "an approval rolled back by the caller's transaction unregisters the tool" do
      ApplicationRecord.transaction do
        @later.approve!
        assert ::Tools::MetaToolService.new.find_schema("lock_probe_b"), "registered while the approval is in flight"
        raise ActiveRecord::Rollback
      end

      assert_not @later.reload.active?
      assert_nil ::Tools::MetaToolService.new.find_schema("lock_probe_b")
      assert_not ::Tools.const_defined?(:LockProbeService, false)
    end

    test "an approval committed by the caller's transaction stays registered" do
      ApplicationRecord.transaction { @later.approve! }

      assert @later.reload.active?
      assert ::Tools::MetaToolService.new.find_schema("lock_probe_b")
    ensure
      ::McpService.delete_tool("lock_probe_b")
    end

    private

    def source(tool_name)
      <<~RUBY
        module Tools
          class LockProbeService
            extend T::Sig
            extend ToolMeta

            tool_name "#{tool_name}"
            tool_description "Lock probe"
            tool_param :creative_id, description: "Creative", required: true

            sig { params(creative_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
            def call(creative_id:)
              { id: creative_id }
            end
          end
        end
      RUBY
    end
  end
end

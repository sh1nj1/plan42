# frozen_string_literal: true

require "test_helper"

module Collavre
  class InlineReplayAdmissionTest < ActiveSupport::TestCase
    # Real commits let another connection see and contend for each source row.
    self.use_transactional_tests = false

    setup do
      @existing_creative_ids = Creative.ids
      @creative = Creative.create!(user: users(:one), description: "Replay admission locks")
      @merged = @creative.comments.create!(user: users(:one), content: "Mention", skip_dispatch: true)
      @anchor = @creative.comments.create!(user: users(:one), content: "Details", skip_dispatch: true)
      @task = Task.create!(name: "Login", agent: users(:ai_bot), creative: @creative,
        topic_id: @anchor.topic_id, status: :done, trigger_event_payload: {
          "comment" => { "id" => @anchor.id }, "merged_comment_ids" => [ @anchor.id, @merged.id, @merged.id.to_s, nil ]
        })
      @card = @creative.comments.create!(user: users(:ai_bot), content: "Login", task: @task, skip_dispatch: true)
      @identity = [ @card.id, users(:one).id, @task.id ]
    end

    teardown do
      Task.where(creative: @creative).destroy_all if @creative
      @creative&.topics&.destroy_all
      @creative&.destroy!
      # Task notifications may create fixture users' inboxes outside this turn.
      Creative.where.not(id: @existing_creative_ids).destroy_all if @existing_creative_ids
    end

    [ false, true ].each do |rollback|
      test "all replay sources stay locked through #{rollback ? 'rollback' : 'commit'} of admission" do
        skip "Row-lock contention requires PostgreSQL" unless Comment.connection.adapter_name == "PostgreSQL"
        login = Object.new
        login.define_singleton_method(:task) { @task }
        login.define_singleton_method(:agent) { @task.agent }
        login.instance_variable_set(:@task, @task)
        validate = lambda do
          [ @merged, @anchor ].each { |source| assert source_locked?(source.id), "Validation must lock source #{source.id}" }
          @task.trigger_event_payload
        end
        login.define_singleton_method(:replay_payload) { validate.call }
        replay_id = nil
        admit = lambda do
          CliProxy::InlineLogin.stub(:new, login) do
            CliProxy::ReplayWorkspace.stub(:permitted?, true) do
              CliProxy::InlineReplayAdmission.call({}, @identity) do |payload|
                replay = Task.create!(name: "Admitted replay", agent: users(:ai_bot), creative: @creative,
                  topic_id: @anchor.topic_id, status: :pending, trigger_event_payload: payload)
                replay_id = replay.id
                [ @merged, @anchor ].each { |source| assert source_locked?(source.id), "Task commit must still hold source #{source.id}" }
                raise "Roll back admission" if rollback
              end
            end
          end
        end
        if rollback
          assert_raises(RuntimeError, &admit)
        else
          admit.call
        end
        assert_equal !rollback, Task.exists?(replay_id)
        [ @merged, @anchor ].each { |source| assert_not source_locked?(source.id), "Admission must release source #{source.id}" }
      end
    end

    test "admission rejects a missing anchor before yielding a task" do
      @anchor.destroy!
      error = assert_raises(CliProxy::Client::Error) do
        CliProxy::InlineReplayAdmission.call({}, @identity) { flunk "Missing source must not create a replay" }
      end
      assert_equal "cannot_retry", error.code
    end

    private

    def source_locked?(id)
      Thread.new do
        Comment.connection_pool.with_connection do |connection|
          connection.transaction do
            connection.execute("SELECT id FROM comments WHERE id = #{Integer(id)} FOR UPDATE NOWAIT")
          end
          false
        rescue ActiveRecord::LockWaitTimeout
          true
        end
      end.value
    end
  end
end

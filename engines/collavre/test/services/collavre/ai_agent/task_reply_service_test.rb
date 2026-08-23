# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class TaskReplyServiceTest < ActiveSupport::TestCase
      test "keeps an active claim between locked comment save and locked finalize" do
        user = users(:one)
        creative = Creative.create!(description: "Replies", user: user)
        topic = creative.topics.create!(name: "Delegated", user: user)
        events = []
        task = Object.new
        claim_service = Object.new
        claim_service.define_singleton_method(:link_reply) { |**| events << :link }
        claim_service.define_singleton_method(:finalize) { |**| events << :finalize }
        lock = lambda do |&block|
          events << :lock
          block.call.tap { events << :unlock }
        end

        topic.stub(:with_lock, lock) do
          result = TaskReplyService.new(
            topic: topic, current_user: user, text: "done", requested_task_id: 123,
            agent_resolver: ->(*) { user }, task_claimer: ->(*) { events << :claim; task },
            claim_service: claim_service
          ).call

          assert_equal :created, result.status
          assert result.comment.persisted?
        end

        assert_equal %i[lock claim link unlock finalize], events
      end

      test "active claimed reply blocks a topic move before finalize" do
        user = users(:one)
        source = Creative.create!(description: "Replies", user: user)
        destination = Creative.create!(description: "Destination", user: user)
        topic = source.topics.create!(name: "Delegated", user: user)
        task = Task.create!(name: "Reply", creative: source, topic_id: topic.id, agent: user, status: "delegated")
        claim_service = TaskClaimService.new
        finalizer = Object.new
        test_case = self
        finalizer.define_singleton_method(:link_reply) { |**args| claim_service.link_reply(**args) }
        finalizer.define_singleton_method(:finalize) do |**|
          test_case.assert_raises(Topics::TopicMove::ActiveTaskError) do
            Topics::TopicMove.new(topic: topic, target_creative: destination).call
          end
        end

        result = TaskReplyService.new(
          topic: topic, current_user: user, text: "done", requested_task_id: task.id,
          agent_resolver: ->(*) { user },
          task_claimer: ->(agent, locked_topic, task_id) {
            claim_service.claim(agent: agent, topic: locked_topic, requested_task_id: task_id)
          },
          claim_service: finalizer
        ).call

        assert_equal :created, result.status
        assert_equal "running", task.reload.status
        assert_equal source.id, topic.reload.creative_id
        assert_equal task.id, result.comment.reload.task_id
      end
    end
  end
end

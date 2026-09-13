# frozen_string_literal: true

module Collavre
  class WorkflowPushJob < ApplicationJob
    queue_as :default
    def perform(id, token)
      delivery = CommentNotificationDelivery.find_by(id: id)
      Workflow::PushDelivery.new(delivery).perform!(token) if delivery&.workflow_execution_id
    end
  end
end

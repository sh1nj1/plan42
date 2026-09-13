# frozen_string_literal: true

module Collavre
  class WorkflowOutboxJob < ApplicationJob
    queue_as :ai_agents
    def perform(id, token)
      Workflow::Outbox.find_by(id: id)&.deliver!(token)
    end
  end
end

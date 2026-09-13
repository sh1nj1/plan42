# frozen_string_literal: true

module Collavre
  class WorkflowSweepJob < ApplicationJob
    queue_as :default
    def perform
      Workflow::Execution.unfinished.find_each { |row| Workflow::Recovery.execution(row) }
      Workflow::Outbox.unfinished.find_each { |row| Workflow::Recovery.outbox(row) }
    end
  end
end

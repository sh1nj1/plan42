# frozen_string_literal: true

module Collavre
  # Backstop for Orchestration::DeliveryRecord.restore!, which runs from a
  # status callback and therefore after the point where its own failure could
  # still be undone. See DeliveryRecord.restore_missed! for why nothing has to
  # be written down for this to work.
  #
  # Scheduled in config/recurring.yml.
  class RestoreDroppedDispatchesJob < ApplicationJob
    queue_as :default

    def perform
      Orchestration::DeliveryRecord.restore_missed!
    end
  end
end

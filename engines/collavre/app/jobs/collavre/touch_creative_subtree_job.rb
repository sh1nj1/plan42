# frozen_string_literal: true

module Collavre
  class TouchCreativeSubtreeJob < ApplicationJob
    queue_as :default

    def perform(creative_id)
      creative = Creative.find_by(id: creative_id)
      return unless creative

      creative.descendants.update_all(updated_at: Time.current)
    end
  end
end

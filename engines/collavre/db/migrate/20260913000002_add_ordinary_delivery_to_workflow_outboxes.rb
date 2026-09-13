# frozen_string_literal: true

class AddOrdinaryDeliveryToWorkflowOutboxes < ActiveRecord::Migration[8.0]
  def change
    add_column :workflow_outboxes, :ordinary_delivery, :json
  end
end

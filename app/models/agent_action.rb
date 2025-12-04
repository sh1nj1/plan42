class AgentAction < ApplicationRecord
  belongs_to :agent_run

  validates :tool_name, presence: true
  validates :status, presence: true

  enum :status, {
    pending: "pending",
    running: "running",
    success: "success",
    error: "error"
  }, default: :pending
end

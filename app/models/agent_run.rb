class AgentRun < ApplicationRecord
  belongs_to :creative
  belongs_to :ai_user, class_name: "User"
  has_many :agent_actions, dependent: :destroy

  validates :goal, presence: true
  validates :status, presence: true

  enum :state, {
    planning: "planning",
    acting: "acting",
    completed: "completed",
    failed: "failed"
  }, default: :planning

  enum :status, {
    pending: "pending",
    running: "running",
    success: "success",
    error: "error"
  }, default: :pending
end

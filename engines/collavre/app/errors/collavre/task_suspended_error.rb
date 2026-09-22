# frozen_string_literal: true

module Collavre
  # Raised inside an AiAgentJob call stack after Orchestration::TaskResumer
  # has suspended the task, to unwind the turn without ending it. AiAgentJob
  # rescues it ahead of its generic failure handler so the suspension is not
  # overwritten by `failed` and no terminal drain runs for a turn that will be
  # resumed.
  class TaskSuspendedError < StandardError
  end
end

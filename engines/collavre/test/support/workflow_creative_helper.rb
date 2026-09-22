# frozen_string_literal: true

module WorkflowCreativeHelper
  def create_workflow(description: "Workflow", **attributes)
    create_workflow_creative(description:, data: { "kind" => "workflow" }, **attributes)
  end

  def create_workflow_rule(parent:, event: "comment_created", handler: { "type" => "human" }, **attributes)
    payload = { "on" => event, "handler" => handler }
    create_workflow_creative(
      description: attributes.delete(:description) || "Workflow rule",
      parent:,
      data: { "kind" => "workflow_rule", "workflow_rule" => payload },
      **attributes
    )
  end

  def create_workflow_creative(description:, user: users(:one), **attributes)
    Creative.create!({ user:, description:, progress: 0.0 }.merge(attributes))
  end
end

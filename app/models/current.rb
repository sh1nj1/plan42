class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :creative_share_cache
  attribute :mcp_tool_approval_required
  attribute :user

  def user
    super || session&.user
  end
end

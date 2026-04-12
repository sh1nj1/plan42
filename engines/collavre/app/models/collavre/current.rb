# frozen_string_literal: true

module Collavre
  class Current < ActiveSupport::CurrentAttributes
    attribute :session
    attribute :creative_share_cache
    attribute :mcp_tool_approval_required
    attribute :mcp_request
    attribute :user
    attribute :markdown_sync

    def user
      super || session&.user
    end

    def markdown_sync?
      !!markdown_sync
    end
  end
end

# frozen_string_literal: true

# A shared agent fans out to many concurrent sessions, each with its own
# presence row. The HTTP unregister path (DELETE /api/v1/agent/:id) needs to
# drop ONLY the exiting session's row before deciding whether a sibling is
# still live — otherwise the plugin's close-WS-then-DELETE ordering lets a
# session's own still-live row masquerade as a sibling and skip the
# last-session teardown. The WS token is server-minted and unknown to the HTTP
# client; session_id (stable across --resume, sent by the plugin) is the
# identity the DELETE can correlate to. Nullable: topic-stream/legacy
# subscribers have no session_id.
class AddSessionIdToAgentSubscriptions < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_subscriptions, :session_id, :string
    add_index :agent_subscriptions, [ :agent_id, :session_id ]
  end
end

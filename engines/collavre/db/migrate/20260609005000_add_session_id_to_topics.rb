# frozen_string_literal: true

# Claude Channel Agent/Session split: a Session (one Claude Code session) maps
# to one Topic, identified by a stable session_id (derived per cwd by the
# plugin, stable across --resume). The Agent (ai_user) is now shared across a
# human's sessions, so the topic can no longer be located by the per-agent name
# alone — multiple session topics share one primary_agent. session_id is that
# per-session key.
class AddSessionIdToTopics < ActiveRecord::Migration[8.0]
  def change
    add_column :topics, :session_id, :string
    # Look up a session topic by (primary_agent_id, session_id) on re-register.
    add_index :topics, [ :primary_agent_id, :session_id ],
              name: "index_topics_on_primary_agent_and_session"
  end
end

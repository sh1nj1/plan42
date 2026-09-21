# frozen_string_literal: true

module Collavre
  module AiAgent
    # Provisions the identities a Claude Code registration needs:
    #   - one shared ai_user per (human, agent_name) — the Agent identity
    #   - one Topic per (agent, session_id) — the Session identity
    #
    # Extracted from Api::V1::AgentsController#register so the action stays a
    # thin orchestration of provisioning + inbox share. Behavior is identical to
    # the inlined controller methods it replaces.
    class SessionProvisioner
      def initialize(user)
        @user = user
      end

      # One ai_user per (user, agent_name) so a human's sessions share one Agent
      # identity. Same agent_name re-registering reuses the existing row —
      # idempotent retries (and every additional session) don't proliferate
      # agents.
      #
      # Returns nil when a row with the deterministic email already exists but is
      # owned by someone else or isn't a Claude Channel ai_user. The email format
      # is human-derivable (user.id + slug + digest), so a foreign row could be
      # planted by signup/import; silently reusing it would attach the caller's
      # inbox feedback share to that foreign User and leave the plugin's
      # AgentChannel subscription rejected on ownership mismatch. Caller renders
      # 409 in that case.
      def find_or_create_agent(agent_name)
        email = session_agent_email(agent_name)

        existing = User.find_by(email: email)
        return verified_agent(existing) if existing

        User.create!(
          email: email,
          name: "Claude Channel (#{agent_name})",
          password: SecureRandom.hex(32),
          llm_vendor: "anthropic",
          llm_model: "claude-code",
          created_by_id: @user.id,
          searchable: false
        )
      rescue ActiveRecord::RecordNotUnique
        # A concurrent registration for the same (user, agent_name) won the
        # users.email unique race. The desired row now exists — re-find and
        # re-verify ownership instead of surfacing a 500 that aborts one of the
        # two simultaneously launching plugin instances.
        verified_agent(User.find_by(email: email))
      end

      # One Topic per (agent, session_id). On re-register (including --resume from
      # the same cwd, which yields the same session_id) the existing topic is
      # reused — even if archived — so the conversation persists instead of
      # orphaning. A fresh session gets a new topic under the same shared agent,
      # which is how one agent fans out to many sessions.
      def find_or_create_topic(inbox, ai_user, session_id, session_label)
        existing = inbox.topics.find_by(primary_agent_id: ai_user.id, session_id: session_id)
        return existing if existing

        label = session_label.to_s.strip.presence || session_id
        inbox.topics.create!(
          name: unique_topic_name(inbox, "Claude #{label}"),
          user: @user,
          primary_agent_id: ai_user.id,
          session_id: session_id
        )
      end

      private

      # Deterministic, collision-free email key for a (user, agent_name) agent.
      # The readable slug is lossy — "qa/bot", "qa bot" and "qa--bot" all squeeze
      # to "qa-bot", and any all-symbol name collapses to "session" — so a short
      # digest of the normalized raw name disambiguates distinct configured names
      # that would otherwise alias onto ONE shared agent identity (ActionCable
      # stream, routing state, tasks, creative shares). The slug stays for human
      # readability; the digest decides identity. Same normalized name -> same
      # key, so idempotent re-register/reuse is preserved. Normalization
      # (strip+downcase) keeps case/whitespace-only differences folded, matching
      # the prior behavior — only the lossy punctuation/spacing collapse is fixed.
      def session_agent_email(agent_name)
        normalized = agent_name.to_s.strip.downcase
        slug = normalized.gsub(/[^a-z0-9-]+/, "-").squeeze("-").gsub(/\A-|-\z/, "")
        slug = "session" if slug.blank?
        digest = Digest::SHA256.hexdigest(normalized)[0, 10]
        "claude-channel-#{@user.id}-#{slug}-#{digest}@agent.collavre.local"
      end

      # Returns the agent only when it is the current user's own Claude Channel
      # agent; nil otherwise (the caller renders :conflict). Presence creation
      # stays deferred to AgentChannel#subscribe_to_agent_stream so the agent
      # becomes ambiently routable only once a WebSocket subscriber exists for
      # agent:user:<id> — otherwise comments matched between register returning
      # and the client's subsequent cable subscribe would broadcast into an empty
      # stream, stranding delegated tasks until stuck recovery.
      def verified_agent(ai_user)
        return nil unless ai_user &&
                          ai_user.created_by_id == @user.id &&
                          ai_user.ai_user? &&
                          ai_user.claude_channel_agent?

        ai_user
      end

      # Topics carry a UNIQUE (creative_id, name) index, so two sessions whose
      # friendly labels collide (e.g. both rooted at a dir named "src") cannot
      # share a name. Append the smallest numeric suffix that is free.
      def unique_topic_name(inbox, desired)
        return desired unless inbox.topics.exists?(name: desired)

        n = 2
        loop do
          candidate = "#{desired} (#{n})"
          return candidate unless inbox.topics.exists?(name: candidate)

          n += 1
        end
      end
    end
  end
end

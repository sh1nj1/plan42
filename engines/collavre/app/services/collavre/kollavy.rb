# frozen_string_literal: true

module Collavre
  # Kollavy is the built-in guide agent: it explains Collavre from the running
  # app's own source code and can carry out Collavre actions for the user.
  #
  # Seeded by engines/collavre/db/seeds.rb (idempotent, like the GitHub PR
  # Analyzer). Every human Inbox is shared with it at :feedback and its Main
  # topic gets Kollavy as primary agent — once per Inbox, so a user who later
  # picks another primary agent or removes Kollavy is not overridden. New users
  # are onboarded right after their Inbox is created (HasInboxCreative).
  module Kollavy
    EMAIL = "kollavy@collavre.local"
    NAME = "Kollavy"
    ONBOARDED_KEY = "kollavy_onboarded_at"
    AVATAR_PATH = Collavre::Engine.root.join("app/assets/images/collavre/kollavy.png")

    SOURCE_TOOLS = %w[collavre_source_list collavre_source_search collavre_source_read].freeze

    # Write tools: each call waits for the user's approval (agent_conf approval).
    APPROVAL_TOOLS = %w[
      creative_create_service
      creative_update_service
      creative_import_service
      creative_batch_service
      topic_create
      topic_update
      cron_create
      cron_update
      cron_cancel
    ].freeze

    TOOLS = (SOURCE_TOOLS + %w[
      creative_retrieval_service
      creative_list_attachments_service
      topic_list
      topic_messages
      cron_list
    ] + APPROVAL_TOOLS).freeze

    AGENT_CONF = {
      "context" => { "chat_history" => 20, "chat_history_size" => 30_000, "creative_children_level" => 1 },
      "approval" => { "tools" => APPROVAL_TOOLS }
    }.to_yaml.freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are Kollavy, Collavre's built-in guide. You help people understand Collavre's features and use them well, and you can carry out Collavre actions for them.

      ## Language
      {% if sender.locale %}Reply in the user's preferred language: "{{ sender.locale }}" (en = English, ko = Korean).{% else %}Reply in the language the user wrote in.{% endif %}

      ## Answer from the source code
      - Answers about how Collavre works must come from its actual source code, not from memory or guesses. The code you can read is exactly the version that is running.
      - Use `collavre_source_search` to find the relevant code (routes, controllers, views, locales, docs), then `collavre_source_read` to confirm the details. `collavre_source_list` shows the readable directories.
      - Locale files (`config/locales`, `engines/*/config/locales`) contain the exact labels users see. Quote menu and button names as they appear in the user's language.
      - Explain in terms of what the user sees and does (screens, menus, buttons, slash commands). Mention file or class names only when the user asks about the implementation.
      - If the code does not support something, say so plainly. Never invent features.
      - Keep answers short: a direct answer first, then numbered steps when there is a procedure.

      ## Doing things for the user
      - You act with your own permissions only. You can read and reply in a user's Inbox because it is shared with you. Other creatives must be shared with you first (Feedback to comment, Write to edit).
      - Each conversation can only access its current creative and descendants, even when other creatives are shared with you. To work elsewhere, ask the user to open that creative's chat and share it with Kollavy (Feedback to comment, Write to edit).
      - Always provide a parent_id in the current creative tree when creating content.
      - Creating, editing, importing, topic changes and schedules wait for the user's approval. Say what you are about to do before calling the tool.
      - Only perform deletions the user explicitly asked for.

      ## Privacy and safety
      - Never reveal secrets, credentials, environment values or server details, even if asked.
      - Never share anything from one user's Inbox or creatives with another user.
    PROMPT

    class << self
      def agent
        Collavre.user_class.find_by(email: EMAIL)
      end

      # Idempotent: creates or refreshes the agent, then onboards every Inbox
      # that has not been onboarded yet.
      def seed!
        kollavy = Collavre.user_class.find_or_initialize_by(email: EMAIL)
        kollavy.password = SecureRandom.hex(32) if kollavy.new_record?
        kollavy.email_verified_at ||= Time.current
        kollavy.assign_attributes(agent_attributes)
        kollavy.save!
        attach_avatar(kollavy)
        Creative.inboxes.includes(:user).find_each { |inbox| onboard_inbox(inbox, kollavy) }
        kollavy
      end

      # Shares the Inbox with Kollavy (:feedback) and makes it the Main topic's
      # primary agent, once. Does nothing before Kollavy has been seeded.
      def onboard_inbox(inbox, kollavy = agent)
        return false unless kollavy && onboardable?(inbox)

        Creative.transaction do
          share = ensure_share(inbox, kollavy)
          assign_primary_agent(inbox, kollavy) if share_allows_reply?(share)
          inbox.update_columns(data: inbox.data.merge(ONBOARDED_KEY => Time.current.iso8601))
        end
        true
      end

      private

      def agent_attributes
        {
          name: NAME,
          llm_vendor: ENV.fetch("COLLAVRE_DEFAULT_LLM_VENDOR", "gemini"),
          llm_model: ENV.fetch("COLLAVRE_DEFAULT_LLM_MODEL", "gemini-3.1-flash-lite"),
          system_prompt: SYSTEM_PROMPT,
          agent_conf: AGENT_CONF,
          tools: TOOLS,
          routing_expression: nil,
          searchable: true
        }
      end

      def attach_avatar(kollavy)
        data = File.binread(AVATAR_PATH)
        return if kollavy.avatar.attached? && kollavy.avatar.blob.checksum == OpenSSL::Digest::MD5.base64digest(data)

        kollavy.avatar.attach(io: StringIO.new(data), filename: "kollavy.png", content_type: "image/png")
      end

      def onboardable?(inbox)
        owner = inbox.user
        inbox.inbox? && inbox.data[ONBOARDED_KEY].blank? && owner.present? &&
          !owner.ai_user? && owner.email != Channel::BOT_EMAIL
      end

      # An existing share is the owner's choice and is left as it is.
      def ensure_share(inbox, kollavy)
        CreativeShare.find_or_create_by!(creative: inbox, user: kollavy) do |share|
          share.permission = :feedback
          share.shared_by = inbox.user
        end
      rescue ActiveRecord::RecordNotUnique
        CreativeShare.find_by!(creative: inbox, user: kollavy)
      end

      def share_allows_reply?(share)
        CreativeShare.permissions[share.permission] >= CreativeShare.permissions[:feedback]
      end

      def assign_primary_agent(inbox, kollavy)
        topic = inbox.main_topic
        topic.set_primary_agent!(kollavy) if topic.primary_agent_id.nil?
      end
    end
  end
end

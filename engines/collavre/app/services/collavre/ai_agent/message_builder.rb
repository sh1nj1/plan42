# frozen_string_literal: true

module Collavre
  module AiAgent
    # Builds the message array for AI agent conversations.
    #
    # Extracts creative context, chat history, and the trigger comment
    # into the format expected by AiClient.
    class MessageBuilder
      def initialize(agent:, context:, original_comment: nil)
        @agent = agent
        @context = context
        @original_comment = original_comment
      end

      def build
        messages = []
        @injected_creative_ids = Set.new

        append_creative_context(messages)
        append_context_creatives(messages)
        append_referenced_creative_contexts(messages)
        history_count = append_chat_history(messages)
        append_trigger_message(messages)

        {
          messages: messages,
          first_message: history_count == 0,
          context_changed: history_count > 0 && context_changed_since_last_reply?
        }
      end

      private

      def append_creative_context(messages)
        creative_id = @context.dig("creative", "id")
        return unless creative_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        effective = creative.effective_origin(Set.new)
        topic = current_topic
        topic_info = topic ? "\nTopic: #{topic.name} (id: #{topic.id})" : ""

        if effective.data&.dig("disabled_self_context") == true
          # Self-context disabled: inject only the ancestry chain so the AI
          # knows where in the hierarchy the conversation is happening
          ancestry = build_ancestry_chain(creative)
          @injected_creative_ids << creative.id
          messages << { role: "user", kind: :creative_context, parts: [ { text: "Current Creative (id: #{creative.id}):#{topic_info}\nPath: #{ancestry}" } ] }
        else
          # Full self-context: inject the creative subtree
          children_level = @agent.creative_children_level
          max_depth = 1 + children_level
          markdown = ApplicationController.helpers.render_creative_tree_markdown(
            [ creative ], 1, true, max_depth: max_depth
          )

          @injected_creative_ids << creative.id
          messages << { role: "user", kind: :creative_context, parts: [ { text: "Creative (id: #{creative.id}):#{topic_info}\n#{markdown}" } ] }
        end
      end

      def build_ancestry_chain(creative)
        creative.self_and_ancestors.reverse.map(&:creative_snippet).join(" > ")
      end

      def append_context_creatives(messages)
        creative_id = @context.dig("creative", "id")
        return unless creative_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        effective_origin = creative.effective_origin(Set.new)
        context_ids = effective_origin.effective_context_ids
        disabled_ids = effective_origin.effective_disabled_context_ids
        active_ids = context_ids - disabled_ids - [ creative_id, effective_origin.id ]
        return if active_ids.empty?

        children_level = @agent.creative_children_level
        max_depth = 1 + children_level

        ids_to_load = active_ids.reject { |ctx_id| @injected_creative_ids.include?(ctx_id) }
        creatives_by_id = Creative.where(id: ids_to_load).index_by(&:id)

        active_ids.each do |ctx_id|
          next if @injected_creative_ids.include?(ctx_id)

          ctx = creatives_by_id[ctx_id]
          next unless ctx

          @injected_creative_ids << ctx_id
          markdown = ApplicationController.helpers.render_creative_tree_markdown(
            [ ctx ], 1, true, max_depth: max_depth
          )

          messages << {
            role: "user",
            kind: :context_creative,
            parts: [ { text: "Context Creative (id: #{ctx.id}):\n#{markdown}" } ]
          }
        end
      end

      def append_referenced_creative_contexts(messages)
        content = @context.dig("comment", "content")
        return unless content

        children_level = @agent.creative_children_level
        max_depth = 1 + children_level

        # Extract creative IDs from markdown links like [title](/creatives/123)
        referenced_ids = content.scan(%r{\[[^\]]*\]\(/creatives/(\d+)\)}).flatten.uniq.map(&:to_i)
        referenced_ids.reject! { |cid| @injected_creative_ids.include?(cid) }
        creatives_by_id = Creative.where(id: referenced_ids).index_by(&:id)

        referenced_ids.each do |creative_id|
          creative = creatives_by_id[creative_id]
          next unless creative

          @injected_creative_ids << creative_id
          markdown = ApplicationController.helpers.render_creative_tree_markdown(
            [ creative ], 1, true, max_depth: max_depth
          )

          messages << {
            role: "user",
            kind: :referenced_creative,
            parts: [ { text: "Referenced Creative (id: #{creative.id}):\n#{markdown}" } ]
          }
        end
      end

      # Appends chat history messages and returns the count of messages added.
      def append_chat_history(messages)
        creative_id = @context.dig("creative", "id")
        return 0 unless creative_id

        topic_id = trigger_comment&.topic_id

        history_limit = @agent.chat_history_limit
        history_size_limit = @agent.chat_history_size_limit
        history_chars = 0
        count = 0

        Comment.public_only.where(creative_id: creative_id)
               .where(topic_id: topic_id)
               .where.not(user_id: nil)
               .includes(:user)
               .order(created_at: :desc)
               .limit(history_limit)
               .reverse
               .each do |c|
          next if c.id == trigger_comment&.id

          role = (c.user_id == @agent.id) ? "model" : "user"
          content = c.content.to_s

          if role == "user"
            content = MentionParser.strip_self_mention(content, @agent.name)
            speaker = c.user&.name || "unknown"
            content = "[#{speaker}]: #{content}"
          end

          history_chars += content.length
          break if history_chars > history_size_limit

          messages << { role: role, kind: :chat_history, parts: [ { text: content } ] }
          count += 1
        end

        count
      end

      def append_trigger_message(messages)
        payload_text = @context.dig("comment", "content") || @context.to_json

        if review_eligible?
          quoted_body = @original_comment.quoted_comment&.content
          review_context = I18n.t("collavre.ai_agent.review.context")
          review_parts = [ review_context ]
          review_parts << "---\nOriginal message:\n#{quoted_body}\n---" if quoted_body.present?
          payload_text = "#{review_parts.join("\n\n")}\n\n#{payload_text}"
        end

        sender_name = @context.dig("sender", "name")
        if sender_name
          payload_text = MentionParser.strip_self_mention(payload_text, @agent.name)
          payload_text = "[#{sender_name}]: #{payload_text}"
        end

        trigger_parts = [ { text: payload_text } ]

        if @original_comment&.images&.attached?
          @original_comment.images.each do |image|
            trigger_parts << { image: image.blob }
          end
        end

        messages << { role: "user", kind: :trigger, parts: trigger_parts }
      end

      def trigger_comment
        @trigger_comment ||= begin
          id = @context.dig("comment", "id")
          Comment.find_by(id: id) if id
        end
      end

      def current_topic
        return unless trigger_comment&.topic_id

        Topic.find_by(id: trigger_comment.topic_id)
      end

      def review_eligible?
        ReviewHandler.eligible?(@original_comment, @agent)
      end

      # Detects whether creative context or agent settings have changed
      # since the agent's last reply in this topic. Used to decide whether
      # to re-send system prompt and context to the Gateway.
      #
      # Checks the injected creatives AND their rendered subtrees (descendants
      # up to max_depth), since render_creative_tree_markdown includes children.
      def context_changed_since_last_reply?
        creative_id = @context.dig("creative", "id")
        return false unless creative_id

        topic_id = trigger_comment&.topic_id

        last_reply_at = Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: @agent.id)
                               .maximum(:created_at)
        return true unless last_reply_at

        # Collect all IDs that were rendered (roots + their subtrees)
        all_rendered_ids = collect_rendered_creative_ids

        creative_changed = Creative.where(id: all_rendered_ids)
                                   .where("updated_at > ?", last_reply_at)
                                   .exists?
        agent_changed = @agent.updated_at > last_reply_at

        creative_changed || agent_changed
      end

      # Collects the IDs of all creatives whose content is included in the
      # rendered context: each injected root plus its full subtree.
      # This is slightly broader than what's actually rendered (which is
      # limited by children_level), but ensures no descendant change is missed.
      def collect_rendered_creative_ids
        roots = Creative.where(id: @injected_creative_ids.to_a).to_a
        found_ids = roots.map(&:id).to_set

        roots.flat_map(&:subtree_ids)
             .concat(@injected_creative_ids.reject { |rid| found_ids.include?(rid) })
             .uniq
      end
    end
  end
end

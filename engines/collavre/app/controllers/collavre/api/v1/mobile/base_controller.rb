# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Mobile
        # Shared base for the voice-companion mobile API. Inherits Doorkeeper
        # bearer auth from Api::V1::BaseController.
        #
        # ★ The API base controller authenticates the token but does NOT run the
        # host app's locale around_action, so I18n would otherwise serve the
        # process-default locale. Every persisted/spoken string here must match
        # the speaker, so we wrap every action in I18n.with_locale (app-supplied
        # `locale` param wins, else the user's stored locale).
        class BaseController < Collavre::Api::V1::BaseController
          around_action :with_request_locale

          private

          def with_request_locale(&block)
            I18n.with_locale(requested_locale, &block)
          end

          def requested_locale
            normalize_locale(params[:locale].presence || current_user&.locale)
          end

          def normalize_locale(value)
            return I18n.default_locale if value.blank?

            base = value.to_s.tr("-", "_").split("_").first.to_sym
            I18n.available_locales.include?(base) ? base : I18n.default_locale
          end

          def summarizer
            @summarizer ||= Collavre::Mobile::EventSummarizer.new(locale: I18n.locale)
          end

          # User-owned AI agents (Claude Channel sessions, etc.).
          def agent_ids
            @agent_ids ||= Collavre::User.ai_agents.where(created_by_id: current_user.id).pluck(:id)
          end

          # Undecided permission prompts the token holder is the approver for.
          def pending_approvals
            Collavre::Comment.where(approver_id: current_user.id, action_executed_at: nil)
                             .where.not(action: nil)
                             .order(:created_at)
                             .limit(50)
                             .select(&:claude_channel_permission?)
          end

          def reply(key)
            I18n.t("collavre.mobile.reply.#{key}")
          end

          def label_for_topic(topic_id)
            topic = topic_id && Collavre::Topic.find_by(id: topic_id)
            topic&.name.presence || I18n.t("collavre.mobile.default_task_label")
          end

          # List/display title for an event: "Creative#Topic" so the app can show
          # which thread a message belongs to (spec: 제목을 크리에이티브#토픽 형태로).
          # The creative half uses #creative_snippet — the SAME helper the web chat
          # header renders (HTML-stripped, unescaped, truncated to 24 chars) — so a
          # description full of markup/markdown is shown as readable plain text and
          # the app title matches what users see in Collavre's chat UI.
          def title_for_topic(topic_id)
            topic = topic_id && Collavre::Topic.find_by(id: topic_id)
            name = topic&.name.presence || I18n.t("collavre.mobile.default_task_label")
            snippet = topic&.creative&.creative_snippet.presence
            snippet ? "#{snippet}##{name}" : name
          end

          def render_speak(reply_key_or_text, action: {}, speak: true, status: :ok)
            text = reply_key_or_text.is_a?(Symbol) ? reply(reply_key_or_text) : reply_key_or_text
            render json: { reply: text, speak: speak, action: action }, status: status
          end

          # Gate + decide + broadcast a Claude Channel permission. Routes the
          # voice path through the same approval_status gate the web path uses
          # (Comments::ApprovalActions). Without this the caller could decide a
          # prompt they merely own the authoring agent for but are not the
          # designated approver of (authorized_comment? lets agent-owned events
          # through). Returns a symbol: :ok | :unauthorized | :already_decided.
          def decide_permission(comment, behavior)
            return :unauthorized unless comment.can_be_approved_by?(current_user)

            comment.decide_claude_channel_permission!(behavior, by: current_user)
            comment.broadcast_claude_channel_permission_decision(behavior)
            :ok
          rescue Collavre::Comment::ClaudeChannelPermission::AlreadyDecided
            :already_decided
          end
        end
      end
    end
  end
end

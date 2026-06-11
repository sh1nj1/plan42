# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Mobile
        # Context-free voice commands (no specific event in hand): global control
        # ("1번 멈춰", "전부 승인", "상태 알려줘") and free-form task starts
        # ("OpenClaw PR 검토해"). Hybrid resolver decides the intent; the server
        # resolves the spoken ref against the live registry and performs the
        # action. Low-confidence LLM results ask for confirmation instead of
        # acting — a misheard word must never silently fire an irreversible
        # decision.
        #
        # Future on-device-LLM seam: this also accepts a pre-structured
        # `intent` payload, bypassing the text resolver (see resolve_intent).
        class VoiceCommandsController < BaseController
          CONFIDENCE_FLOOR = 0.5

          def create
            res = resolve_intent

            case res.intent
            when "approve", "deny" then apply_decision(res)
            when "stop"            then control_stop(res)
            when "continue"        then control_continue(res)
            when "status"          then status_report
            else                        relay_or_start(params[:text].to_s)
            end
          end

          private

          def resolve_intent
            if (intent = params[:intent]).present? && intent.respond_to?(:[])
              # On-device LLM already structured it — trust it, full confidence.
              Collavre::Mobile::CommandResolver::Resolution.new(
                intent: intent[:type] || intent["type"],
                ref: normalize_ref(intent[:ref] || intent["ref"]),
                behavior: intent[:behavior] || intent["behavior"],
                confidence: 1.0, source: "on_device"
              )
            else
              command_resolver.resolve(params[:text].to_s)
            end
          end

          def normalize_ref(value)
            return nil if value.nil?
            return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

            value.to_s.to_sym
          end

          def apply_decision(res)
            return confirm(res) if uncertain?(res)

            refs = registry.resolve(res.ref).select { |r| r.kind == "approval" }
            return render_speak(:no_match, action: { type: "no_match" }) if refs.empty?

            behavior = res.behavior == "deny" ? "deny" : "allow"
            decided = []
            refused = []
            refs.each do |ref|
              comment = ref.target_comment
              next unless comment&.claude_channel_permission?

              case decide_permission(comment, behavior)
              when :ok
                ref.resolve!
                decided << ref.ref_number
              when :already_decided
                ref.resolve!
              when :unauthorized
                refused << ref.ref_number
              end
            end

            if decided.empty? && refused.any?
              return render_speak(:not_authorized, action: { type: "not_authorized", refs: refused }, status: :forbidden)
            end

            key = behavior == "allow" ? :approved_n : :denied_n
            render_speak(I18n.t("collavre.mobile.reply.#{key}", numbers: decided.join(", ")),
                         action: { type: behavior == "allow" ? "approved" : "denied", refs: decided })
          end

          def control_stop(res)
            return confirm(res) if uncertain?(res)

            refs = registry.resolve(res.ref).select { |r| r.kind == "agent_session" }
            return render_speak(:no_match, action: { type: "no_match" }) if refs.empty?

            stopped = []
            refs.each do |ref|
              task = Collavre::Task.where(topic_id: ref.topic_id, agent_id: agent_ids,
                                          status: %w[queued pending running delegated]).order(:created_at).last
              next unless task

              task.update!(status: "cancelled")
              Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
              ref.resolve!
              stopped << ref.ref_number
            end

            render_speak(I18n.t("collavre.mobile.reply.stopped_n", numbers: stopped.join(", ")),
                         action: { type: "stopped", refs: stopped })
          end

          def control_continue(res)
            refs = registry.resolve(res.ref).select { |r| r.kind == "agent_session" }
            return render_speak(:no_match, action: { type: "no_match" }) if refs.empty?

            relayed = []
            refs.each do |ref|
              topic = Collavre::Topic.find_by(id: ref.topic_id)
              next unless topic

              creative = topic.creative&.effective_origin
              next unless creative

              creative.comments.create!(content: I18n.t("collavre.mobile.continue_message"),
                                        user: current_user, topic: topic)
              relayed << ref.ref_number
            end

            render_speak(I18n.t("collavre.mobile.reply.continued_n", numbers: relayed.join(", ")),
                         action: { type: "continued", refs: relayed })
          end

          def status_report
            refs = registry.active_refs.to_a
            return render_speak(:status_idle, action: { type: "status", count: 0 }) if refs.empty?

            lines = refs.map { |r| I18n.t("collavre.mobile.reply.status_line", number: r.ref_number, label: r.label) }
            render_speak(I18n.t("collavre.mobile.reply.status_header", count: refs.size) + " " + lines.join(" "),
                         action: { type: "status", count: refs.size })
          end

          # Free-form: start a new piece of work by posting to the user's inbox,
          # exactly like typing in the inbox chat — existing dispatch matches an
          # agent via routing_expression.
          def relay_or_start(text)
            return render_speak(:empty_response, action: { type: "noop" }) if text.strip.blank?

            inbox = Collavre::Creative.inbox_for(current_user)
            comment = inbox.comments.create!(content: text, user: current_user)
            render_speak(:sent, action: { type: "message_sent", comment_id: comment.id })
          end

          def uncertain?(res)
            res.source == "llm" && res.confidence < CONFIDENCE_FLOOR
          end

          def confirm(res)
            render_speak(I18n.t("collavre.mobile.reply.confirm", text: params[:text].to_s),
                         action: { type: "needs_confirmation", intent: res.intent, ref: res.ref })
          end
        end
      end
    end
  end
end

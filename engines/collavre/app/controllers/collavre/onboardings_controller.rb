# frozen_string_literal: true

module Collavre
  class OnboardingsController < ApplicationController
    def show
      render json: state
    end

    def advance
      with_current_session do |session|
        Onboarding::ProgressTracker.record(user: Current.user, event: :ui, session: session)
        render json: state
      end
    end

    def complete
      with_current_session do |session|
        Onboarding::CompletionService.new(user: Current.user).call(
          session_id: session.session_id,
          defer_pending_agent_cleanup: true
        )
        render json: { success: true }
      end
    end

    def reset
      Current.user.with_lock do
        previous_session = Onboarding::Session.for_user(Current.user)
        Onboarding::CompletionService.new(user: Current.user).call(
          session_id: previous_session&.session_id,
          defer_pending_agent_cleanup: true
        )
        retire_pending_session!(previous_session)
        Current.user.update!(
          creative_workspace_enabled: true,
          onboarding_seeded_at: nil,
          onboarding_completed_at: nil
        )
        Onboarding::Seeder.new(user: Current.user, force: true).call
      end
      redirect_to creatives_path
    end

    private

    # A card can outlive its session when onboarding is reset in another tab.
    # Lock the user around the comparison and mutation so reset cannot replace
    # the session after this check but before the selected action runs.
    def with_current_session
      Current.user.with_lock do
        session = Onboarding::Session.for_user(Current.user)
        unless session && session.session_id == params[:session_id]
          render json: { error: t("collavre.onboarding.errors.stale_session") }, status: :conflict
          next
        end

        yield session
      end
    end

    # A pending agent turn keeps its old tree until it settles, but that tree
    # cannot remain the active session or reseeding would resume it instead.
    # Keep the session id for the deferred cleanup job and retire only its
    # scenario marker, which is what Session.for_user uses to find the guide.
    def retire_pending_session!(session)
      root = Creative.find_by(id: session&.root&.id)
      return unless root

      root.with_lock do
        onboarding = root.reload.data.fetch("onboarding", {}).deep_dup
        return if onboarding["scenario_key"].blank?

        onboarding.delete("scenario_key")
        root.update!(data: root.data.merge("onboarding" => onboarding))
      end
    end

    def state
      session = Onboarding::Session.for_user(Current.user)
      step = session&.current_step
      return { success: true, current_step: nil } unless session

      instruction = instruction_state(session, step)

      {
        success: true,
        session_id: session.session_id,
        current_step: step&.key,
        anchor: current_anchor(session, step),
        anchor_key: session.anchor_key(step),
        navigation_path: session.navigation_path(step, script_name: request.script_name),
        completion: step&.completion,
        complete: session.data["current_step"] == "complete",
        completed_steps: session.data.fetch("steps", {}).select { |_key, value| value["status"] == "completed" }.keys,
        instruction: instruction.fetch(:text),
        instruction_before: instruction[:before],
        instruction_after: instruction[:after],
        instruction_control: instruction[:control]
      }
    end

    def instruction_state(session, step)
      return { text: t("collavre.onboarding.card.complete") } unless step

      key = "collavre.onboarding.steps.#{step.key}"
      return { text: t("#{key}.body") } unless instruction_control?(session, step)

      {
        text: t("#{key}.body"),
        before: t("#{key}.body_before"),
        after: t("#{key}.body_after"),
        control: { type: step.key, label: t("#{key}.control") }
      }
    end

    def instruction_control?(session, step)
      step.key == :editor || (step.key == :progress && session.added_practice_creative_id.nil?)
    end

    def current_anchor(session, step)
      return "tree.add" if step&.key == :progress && session.added_practice_creative_id.nil?

      step&.anchor
    end
  end
end

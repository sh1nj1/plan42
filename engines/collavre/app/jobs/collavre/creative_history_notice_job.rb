# frozen_string_literal: true

module Collavre
  class CreativeHistoryNoticeJob < ApplicationJob
    queue_as :default

    def perform(change_set_id, user_id)
      change_set = CreativeChangeSet.includes(:creative_changes).find_by(id: change_set_id)
      user = User.find_by(id: user_id)
      return unless change_set&.status == "applied" && change_set.actor_kind == "agent" && user

      diff = Creatives::ChangeSetDiff.new(change_set, user: user)
      creative = notice_creative(diff)
      return unless creative && diff.revertible?

      I18n.with_locale(user.locale.presence || I18n.default_locale) do
        apply_url = Engine.routes.url_helpers.creative_apply_change_set_path(creative, change_set)
        Turbo::StreamsChannel.broadcast_append_to(
          [ user, :creative_tree ],
          target: "creative-history-toast-container",
          partial: "collavre/creative_change_sets/undo_toast",
          locals: { change_set: change_set, apply_url: apply_url, change_count: diff.change_count }
        )
      end
    end

    private

    def notice_creative(diff)
      root_id = diff.groups.first&.fetch(:root_id)
      Creative.find_by(id: root_id) if root_id
    end
  end
end

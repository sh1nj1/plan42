# frozen_string_literal: true

module Collavre
  module Concerns
    module CreativeHistoryTrackable
      extend ActiveSupport::Concern

      included do
        around_action :track_creative_history,
                      only: %i[create update destroy unconvert update_contexts update_metadata archive unarchive
                               trigger_action reorder link_drop]
      end

      private

      def track_creative_history(&block)
        requested_anchor = Creative.find_by(id: params[:history_anchor_id])
        anchor = requested_anchor if requested_anchor&.has_permission?(Current.user, :read)
        anchor ||= @creative
        Creatives::History.track(
          actor: Current.user,
          origin: :editor,
          anchor: anchor,
          anchor_source: :view_root,
          change_group_token: params[:change_group_token],
          &block
        )
      end
    end
  end
end

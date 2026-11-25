# frozen_string_literal: true

module Collavre
  module PublicCreativeRedirectable
    extend ActiveSupport::Concern

    included do
      before_action :redirect_legacy_public_creative, only: :index
    end

    private

    def turbo_prefetch_request?
      request.headers["X-Sec-Purpose"] == "prefetch"
    end

    def redirect_legacy_public_creative
      return unless request.format.html? && !Current.user && !turbo_frame_request?
      return unless request.query_parameters.keys == [ "id" ]

      creative = Creative.find_by(id: params[:id])
      return unless creative&.has_permission?(nil, :read)

      origin = creative.effective_origin
      return unless origin.publicly_readable?

      redirect_to public_creative_path(public_id: origin.ensure_public_id!, slug: origin.public_slug.presence),
                  status: :moved_permanently
    end
  end
end

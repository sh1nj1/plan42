# frozen_string_literal: true

module Collavre
  # Server-rendered, signed-out view of a publicly shared creative at
  # /p/:public_id/:slug — the address search engines and shared links use.
  #
  # The page always shows what an anonymous reader may see, even to a signed-in
  # visitor, so it never leaks private content and renders the same for
  # everyone. public_id only locates the creative; access is re-checked on every
  # request, so revoking the public share turns the address into a 404.
  class PublicCreativesController < ApplicationController
    allow_unauthenticated_access
    before_action :enforce_creatives_login_policy
    layout "collavre/landing"

    def show
      @creative = Creative.find_by!(public_id: params[:public_id])
      raise ActiveRecord::RecordNotFound unless @creative.origin_id.nil? && @creative.publicly_readable?

      slug = @creative.public_slug
      unless params[:slug].to_s == slug
        return redirect_to(public_creative_path(public_id: @creative.public_id, slug: slug.presence), status: :moved_permanently)
      end

      tree = Creatives::PublicTreeBuilder.new(@creative)
      @nodes = tree.call
      @truncated = tree.truncated?
    end

    private

    def enforce_creatives_login_policy
      require_authentication if SystemSetting.creatives_login_required?
    end
  end
end

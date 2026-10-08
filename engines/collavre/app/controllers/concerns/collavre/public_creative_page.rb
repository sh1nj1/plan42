# frozen_string_literal: true

module Collavre
  # /p/:public_id/:slug — the stable, indexable address of a publicly shared
  # creative, for search engines and shared links.
  #
  # The body is the regular client-rendered creative view a signed-out reader
  # already gets at /creatives?id=, so there is a single renderer for creative
  # content. The server adds only what crawlers and link unfurlers read before
  # any JavaScript runs: title, description, canonical and Open Graph tags (see
  # creatives/_public_meta). Signed-in visitors are sent to the app view.
  #
  # public_id only locates the creative; access is re-checked on every request,
  # so revoking the public share turns the address into a 404.
  module PublicCreativePage
    extend ActiveSupport::Concern

    included do
      helper Collavre::PublicCreativesHelper
    end

    def public_page
      creative = Creative.find_by!(public_id: params[:public_id])
      raise ActiveRecord::RecordNotFound unless public_page_visible?(creative)

      slug = creative.public_slug
      if params[:slug].to_s != slug
        redirect_to public_creative_path(public_id: creative.public_id, slug: slug.presence), status: :moved_permanently
      elsif Current.user
        redirect_to creatives_path(id: creative.id)
      else
        render_public_page(creative)
      end
    end

    private

    def public_page_visible?(creative)
      creative.origin_id.nil? && creative.publicly_readable? && creative.has_permission?(Current.user, :read)
    end

    def render_public_page(creative)
      # The index template and its client-side tree fetch are keyed on params[:id].
      params[:id] = creative.id.to_s
      @public_creative = creative
      @parent_creative = creative
      @creatives = []
      @shared_list = creative.all_shared_users
      render :index
    end
  end
end

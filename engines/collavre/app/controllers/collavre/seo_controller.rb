# frozen_string_literal: true

module Collavre
  # robots.txt and sitemap.xml for the public creative pages.
  #
  # The sitemap lists root creatives that carry their own public share and is
  # still readable signed out; descendants are part of that page's outline
  # rather than separate entries. When creatives require a
  # login there is nothing public to crawl, so robots disallows everything and
  # the sitemap is empty.
  class SeoController < ApplicationController
    allow_unauthenticated_access

    SITEMAP_PAGE_SIZE = 10_000
    CACHE_TTL = 1.hour

    def self.sitemap_page_size
      SITEMAP_PAGE_SIZE
    end

    def robots
      expires_in CACHE_TTL, public: true
      render plain: robots_body, content_type: "text/plain"
    end

    def sitemap
      expires_in CACHE_TTL, public: true
      @creatives = []
      return render(formats: :xml) if SystemSetting.creatives_login_required?

      return render(formats: :xml) unless params[:page].nil? || params[:page].is_a?(String)

      candidates = published_creatives
      page_size = self.class.sitemap_page_size
      page_count = (candidates.count + page_size - 1) / page_size
      if params[:page].blank? && page_count > 1
        @page_count = page_count
        return render(:sitemap_index, formats: :xml)
      end

      page = [ params[:page].to_i, 1 ].max
      return render(formats: :xml) if page > page_count

      @creatives = candidates.order(:id).limit(page_size).offset((page - 1) * page_size)
      render formats: :xml
    end

    private

    # Reads the shares table directly rather than the permission cache: the
    # cache is rebuilt by a background job, and a publicly cached sitemap must
    # not drop a newly published root during that window. A root has no
    # ancestors, so its own non-denying public share is what makes it readable.
    def published_creatives
      shared_ids = CreativeShare.where(user_id: nil).where.not(permission: :no_access).select(:creative_id)
      Creative.active.where(id: shared_ids, origin_id: nil, parent_id: nil).where.not(public_id: nil)
    end

    def robots_body
      return "User-agent: *\nDisallow: /\n" if SystemSetting.creatives_login_required?

      prefix = request.script_name
      # A /p/ page is client-rendered, so crawlers also need its assets, the
      # tree JSON it loads and the attachments in its body. The JSON endpoints
      # only ever return public content to an anonymous request, and attachment
      # URLs are signed, so only ones linked from public content are
      # discoverable.
      <<~ROBOTS
        User-agent: *
        Allow: #{prefix}/p/
        Allow: #{Rails.application.config.assets.prefix}/
        Allow: #{ActiveStorage.routes_prefix}/
        Allow: #{prefix}/public-assets/
        Allow: #{prefix}/creatives?format=json
        Allow: #{prefix}/creatives/*/children
        Disallow: /
        Allow: #{prefix}/sitemap.xml

        Sitemap: #{sitemap_url}
      ROBOTS
    end
  end
end

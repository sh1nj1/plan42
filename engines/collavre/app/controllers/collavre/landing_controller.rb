module Collavre
  class LandingController < ApplicationController
    include Collavre::PublicAssetsHelper

    allow_unauthenticated_access

    # Creative whose file attachments hold the landing demo videos and posters.
    # In production this is the "Landing demo video assets" Creative. The demo
    # URLs are resolved from its live blobs at request time, so the signed ids
    # always match the current environment (no env-bound blob ids frozen into
    # source or locale files).
    LANDING_DEMO_CREATIVE_ID = 16_330

    def show
      @demo = landing_demo_assets
    end

    private

    # Returns { video:, poster:, video_dark:, poster_dark: } as public-asset
    # URLs (or nil) for the current locale, resolved from the demo Creative's
    # attachments. Empty hash when the Creative is absent (e.g. a fresh dev DB).
    def landing_demo_assets
      creative = Collavre::Creative.find_by(id: LANDING_DEMO_CREATIVE_ID)
      return {} unless creative

      blobs = latest_blobs_by_filename(creative)
      prefix = I18n.locale.to_s.start_with?("ko") ? "launch-ko" : "launch"

      {
        video: blobs["#{prefix}.mp4"],
        poster: blobs["#{prefix}-poster.jpg"],
        video_dark: blobs["#{prefix}-dark.mp4"],
        poster_dark: blobs["#{prefix}-dark-poster.jpg"]
      }.transform_values { |blob| blob && public_asset_url(blob) }
    end

    # `has_many_attached :files` appends, so a re-recorded asset shares its
    # filename with the stale one it replaces. Keep only the newest blob per
    # filename so re-recording never requires deleting the old attachment first.
    def latest_blobs_by_filename(creative)
      creative.files.includes(:blob).each_with_object({}) do |attachment, acc|
        blob = attachment.blob
        name = blob.filename.to_s
        current = acc[name]
        acc[name] = blob if current.nil? || blob.created_at > current.created_at
      end
    end
  end
end

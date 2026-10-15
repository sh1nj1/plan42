# frozen_string_literal: true

module Collavre
  # Hardens the ActiveStorage endpoints Rails draws by default. Their stock
  # controllers inherit ActionController::Base, so they skip both the CloudFront
  # origin check and any authentication: a leaked signed_id would download the
  # blob forever. Collavre::Engine installs these modules into the stock
  # controllers (see .install!) instead of disabling the routes, because stored
  # descriptions, comment views and the editor already link to them.
  module ActiveStorageAccess
    SERVING_CONTROLLERS = %w[
      ActiveStorage::Blobs::RedirectController
      ActiveStorage::Blobs::ProxyController
      ActiveStorage::Representations::RedirectController
      ActiveStorage::Representations::ProxyController
    ].freeze

    def self.install!
      SERVING_CONTROLLERS.each { |name| install_once(name.constantize, ServeAuthorization) }
      ActiveStorage::Blobs::ProxyController.prepend(Collavre::SvgStreaming) unless
        ActiveStorage::Blobs::ProxyController.ancestors.any? { |ancestor| ancestor.name == Collavre::SvgStreaming.name }
      install_once(ActiveStorage::DirectUploadsController, UploadAuthentication)
      install_once(ActiveStorage::DiskController, OriginOnly)
    end

    def self.install_once(controller, mod)
      return if controller.ancestors.any? { |ancestor| ancestor.name == mod.name }

      controller.include(mod)
    end
    private_class_method :install_once

    # Blob and representation reads: verify the origin, then authorize the
    # blob before ActiveStorage loads it (and, for representations, before it
    # spends time processing a variant). Responses are never publicly cacheable.
    module ServeAuthorization
      extend ActiveSupport::Concern
      include Collavre::OriginVerification
      include Collavre::BlobAccessControl

      included do
        prepend_before_action :authorize_blob_access!
        prepend_before_action :verify_cloudfront_origin!
      end

      private

      def authorize_blob_access!
        blob = ActiveStorage::Blob.find_signed(params[:signed_blob_id] || params[:signed_id])
        return head(:not_found) unless blob && blob_readable?(blob)

        mark_private_blob_response!
        if blob.content_type == "image/svg+xml" && is_a?(ActiveStorage::Blobs::RedirectController)
          redirect_to Rails.application.routes.url_helpers.rails_storage_proxy_path(
            blob, disposition: params[:disposition], only_path: true
          )
        end
      end

      # The proxy controllers wrap streaming in http_cache_forever(public: true),
      # which would let a CDN or shared cache keep a private blob for 100 years.
      # Stream without it; mark_private_blob_response! already set no-store.
      def http_cache_forever(public: false)
        yield
      end

      # The redirect controllers call expires_in(service_urls_expire_in), which
      # drops no-store and would let a browser replay the cached 302 (and its
      # signed service URL) after access is revoked. Keep no-store.
      def expires_in(*)
      end
    end

    # Direct uploads: only signed-in users (or bearer clients) may create blobs,
    # and the uploader is recorded server-side so the blob stays readable to
    # them before it is attached to anything (see Collavre::BlobAccess).
    module UploadAuthentication
      extend ActiveSupport::Concern
      include Collavre::OriginVerification
      include Collavre::BlobAccessControl

      included do
        prepend_before_action :require_blob_uploader!
        prepend_before_action :verify_cloudfront_origin!
        prepend UploaderMetadata
      end

      private

      def require_blob_uploader!
        head :unauthorized unless blob_viewer
      end

      # ActiveStorage::BaseController forges-protects with :exception, and a
      # bearer client has no authenticity token. A cross-site form cannot set
      # an Authorization header, so a valid bearer token proves intent; cookie
      # sessions still need the CSRF token.
      def verified_request?
        super || bearer_blob_viewer.present?
      end
    end

    # Prepended so it wraps the controller's own #blob_args. The uploader id
    # grants access, so a client-sent value is overwritten.
    module UploaderMetadata
      private

      def blob_args
        args = super
        metadata = args[:metadata].to_h
          .merge(Collavre::BlobAccess::UPLOADER_METADATA_KEY => blob_viewer.id.to_s)
        args.merge(metadata: metadata)
      end
    end

    # Disk-service URLs are short-lived signed tokens minted only after an
    # authorized redirect or direct upload, so they just need the origin check.
    module OriginOnly
      extend ActiveSupport::Concern
      include Collavre::OriginVerification

      included do
        prepend_before_action :verify_cloudfront_origin!
      end
    end
  end
end

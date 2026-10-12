# frozen_string_literal: true

module Collavre
  # Sends one CloudFront invalidation. The job id is the CallerReference, so a
  # retried job re-submits the same batch instead of creating a duplicate.
  # Throttling (e.g. too many wildcard invalidations in progress) and network
  # errors are retried with backoff; a final failure is logged as an error.
  class CdnInvalidationJob < ApplicationJob
    class InvalidationFailed < StandardError; end

    queue_as :default

    retry_on InvalidationFailed, wait: :polynomially_longer, attempts: 8 do |job, error|
      Rails.logger.error("[CdnInvalidationJob] giving up on #{job.arguments.first.inspect}: #{error.message}")
    end

    def perform(paths)
      distribution_id = Collavre::CdnInvalidation.distribution_id
      return if distribution_id.blank? || paths.blank?

      client.create_invalidation(
        distribution_id: distribution_id,
        invalidation_batch: {
          paths: { quantity: paths.size, items: paths },
          caller_reference: "collavre-#{job_id}"
        }
      )
    rescue LoadError => e
      Rails.logger.error("[CdnInvalidationJob] aws-sdk-cloudfront unavailable: #{e.message}")
    rescue StandardError => e
      raise InvalidationFailed, "#{e.class}: #{e.message}" if aws_error?(e)

      raise
    end

    private

    # CloudFront is a global service; its API lives in us-east-1. Uses the S3
    # credential pair when configured, else the default AWS provider chain.
    def client
      require "aws-sdk-cloudfront"
      Aws::CloudFront::Client.new(region: "us-east-1", **Collavre::AwsCredentials.s3)
    end

    def aws_error?(error)
      defined?(Aws::Errors::ServiceError) && error.is_a?(Aws::Errors::ServiceError) ||
        defined?(Seahorse::Client::NetworkingError) && error.is_a?(Seahorse::Client::NetworkingError)
    end
  end
end

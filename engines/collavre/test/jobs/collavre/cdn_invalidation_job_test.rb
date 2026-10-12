# frozen_string_literal: true

require "test_helper"
require "aws-sdk-cloudfront"

module Collavre
  class CdnInvalidationJobTest < ActiveSupport::TestCase
    def with_distribution(id = "E123", &block)
      CdnInvalidation.stub(:distribution_id, id, &block)
    end

    def stubbed_client
      Aws::CloudFront::Client.new(stub_responses: true)
    end

    test "creates one invalidation using the job id as caller reference" do
      client = stubbed_client
      job = CdnInvalidationJob.new([ "/public-assets/blobs/abc/*" ])

      with_distribution do
        Aws::CloudFront::Client.stub(:new, client) { job.perform_now }
      end

      request = client.api_requests.last
      assert_equal :create_invalidation, request[:operation_name]
      assert_equal "E123", request[:params][:distribution_id]
      batch = request[:params][:invalidation_batch]
      assert_equal({ quantity: 1, items: [ "/public-assets/blobs/abc/*" ] }, batch[:paths])
      assert_equal "collavre-#{job.job_id}", batch[:caller_reference]
    end

    test "skips when no distribution is configured or no paths are given" do
      client = stubbed_client

      Aws::CloudFront::Client.stub(:new, client) do
        with_distribution(nil) { CdnInvalidationJob.perform_now([ "/public-assets/*" ]) }
        with_distribution { CdnInvalidationJob.perform_now([]) }
      end

      assert_empty client.api_requests
    end

    test "wraps AWS errors so they are retried" do
      client = stubbed_client
      client.stub_responses(:create_invalidation, "TooManyInvalidationsInProgress")
      job = CdnInvalidationJob.new([ "/public-assets/*" ])

      with_distribution do
        Aws::CloudFront::Client.stub(:new, client) do
          assert_raises(CdnInvalidationJob::InvalidationFailed) { job.perform([ "/public-assets/*" ]) }
        end
      end
    end

    test "re-raises non-AWS errors unchanged" do
      job = CdnInvalidationJob.new([ "/public-assets/*" ])

      with_distribution do
        Aws::CloudFront::Client.stub(:new, ->(**) { raise ArgumentError, "boom" }) do
          assert_raises(ArgumentError) { job.perform([ "/public-assets/*" ]) }
        end
      end
    end

    test "logs and returns when the CloudFront SDK is not installed" do
      job = CdnInvalidationJob.new([ "/public-assets/*" ])

      with_distribution do
        job.stub(:client, -> { raise LoadError, "cannot load such file -- aws-sdk-cloudfront" }) do
          assert_nothing_raised { job.perform([ "/public-assets/*" ]) }
        end
      end
    end
  end
end

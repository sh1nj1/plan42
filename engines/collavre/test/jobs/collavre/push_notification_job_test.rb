require "test_helper"

module Collavre
  # Comment bodies are unbounded, but they are handed to FCM verbatim as the
  # notification body. Production collected 403 permanently-failed pushes from
  # two size rejections — "Message is too large. The maximum is 4K (4096 bytes)."
  # above ~4.8KB, and a bare "INVALID_ARGUMENT: Invalid argument." from 2440
  # bytes up. Retrying those never helps: the payload is the defect. The job has
  # to cap the body before it is sent.
  class PushNotificationJobTest < ActiveSupport::TestCase
    class RecordingService
      attr_reader :requests

      def initialize(&failure)
        @requests = []
        @failure = failure
      end

      def send_message(parent, request)
        @requests << [ parent, request ]
        @failure&.call(request)
        request
      end
    end

    def client_error(message)
      Google::Apis::ClientError.new(message, status_code: 400, body: "{}")
    end

    setup do
      @user = users(:one)
      @device = Device.create!(
        user: @user,
        client_id: "push-job-test-client",
        device_type: :web,
        fcm_token: "push-job-test-token-#{'t' * 120}"
      )
      @service = RecordingService.new
      @original_service = Rails.application.config.x.fcm_service
      @original_project = Rails.application.config.x.fcm_project_id
      Rails.application.config.x.fcm_service = @service
      Rails.application.config.x.fcm_project_id = "test-project"
    end

    teardown do
      Rails.application.config.x.fcm_service = @original_service
      Rails.application.config.x.fcm_project_id = @original_project
    end

    test "keeps the whole request inside the budget for an oversized message" do
      perform("가" * 8000, "/creatives/1")

      assert_operator sent_request_bytes, :<=, PushNotificationJob::MAX_REQUEST_BYTES
    end

    test "keeps the request inside the budget when the link eats the budget" do
      perform("가" * 8000, "/creatives/1?open_comments=true&#{'q' * 600}")

      assert_operator sent_request_bytes, :<=, PushNotificationJob::MAX_REQUEST_BYTES
    end

    test "marks a truncated body as elided" do
      perform("가" * 8000, "/creatives/1")

      assert sent_body.end_with?("…"),
             "expected the truncated body to signal that content was cut"
    end

    test "does not split a multi-byte character while truncating" do
      perform("가" * 8000, "/creatives/1")

      assert sent_body.valid_encoding?, "truncation produced invalid UTF-8"
      assert_equal sent_body, sent_body.scrub("?")
    end

    test "leaves a short message untouched" do
      perform("짧은 알림", "/creatives/1")

      assert_equal "짧은 알림", sent_body
    end

    test "leaves the click target intact while truncating" do
      link = "/creatives/16738?open_comments=true"
      perform("가" * 8000, link)

      message = sent_message
      assert_equal link, message.webpush.fcm_options.link
      assert_equal link, message.data[:path]
    end

    test "sends to every registered device" do
      Device.create!(
        user: @user,
        client_id: "push-job-test-client-2",
        device_type: :pwa,
        fcm_token: "push-job-test-token-2-#{'u' * 120}"
      )

      perform("가" * 8000, "/creatives/1")

      assert_equal 2, @service.requests.size
      @service.requests.each do |_parent, request|
        assert_operator request_bytes(request), :<=, PushNotificationJob::MAX_REQUEST_BYTES
      end
    end

    # A stale endpoint on one device used to abort the loop, so every device
    # registered after it silently went unnotified for that comment.
    test "one device rejecting the payload does not silence the others" do
      second = Device.create!(
        user: @user,
        client_id: "push-job-test-client-2",
        device_type: :pwa,
        fcm_token: "push-job-test-token-2-#{'u' * 120}"
      )
      first_token = Device.order(:id).first.fcm_token
      @service = RecordingService.new do |request|
        raise client_error("Invalid argument.") if request.message.token == first_token
      end
      Rails.application.config.x.fcm_service = @service

      perform("짧은 알림", "/creatives/1")

      assert_equal 2, @service.requests.size
      assert_equal second.fcm_token, @service.requests.last.last.message.token
    end

    test "still retries when the failure is transient" do
      @service = RecordingService.new { raise Google::Apis::ServerError, "Server error" }
      Rails.application.config.x.fcm_service = @service

      assert_raises(Google::Apis::ServerError) { perform("짧은 알림", "/creatives/1") }
    end

    private

    def perform(message, link)
      PushNotificationJob.perform_now(@user.id, message: message, link: link)
    end

    def sent_message
      @service.requests.first.last.message
    end

    def sent_body
      sent_message.notification.body
    end

    def sent_request_bytes
      request_bytes(@service.requests.first.last)
    end

    # Mirrors what google-api-client puts on the wire: the registration token
    # counts against the same budget as the notification.
    def request_bytes(request)
      request.to_json.bytesize
    end
  end
end

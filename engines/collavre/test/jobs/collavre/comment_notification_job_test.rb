require "test_helper"

module Collavre
  class CommentNotificationJobTest < ActiveSupport::TestCase
    test "delivers create notifications for the persisted comment" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      inbox = Creative.inbox_for(creative.user)
      comment = nil

      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
      comment = Comment.create!(creative: creative, user: commenter, content: "job delivery")
      event = comment.notification_event

      assert_difference -> { inbox.comments.count }, 1 do
        CommentNotificationJob.perform_now(comment.id, "created", event)
      end
      assert_equal comment.id, inbox.comments.order(:id).last.quoted_comment_id
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "preview completion does not change the snapshotted notification text" do
      owner = users(:one)
      commenter = users(:two)
      creative = Creative.create!(user: owner, description: "Notification Preview Race")
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: commenter, content: "https://example.com/race")
      event = comment.notification_event
      clear_enqueued_jobs
      formatter = Minitest::Mock.new
      formatter.expect(:format, "[Example](https://example.com/race)")

      CommentLinkFormatter.stub(:new, formatter) do
        CommentLinkPreviewJob.perform_now(comment.id, comment.content, comment.notification_revision)
      end
      CommentNotificationJob.perform_now(comment.id, "created", event)

      notification = inbox.comments.find_by!(quoted_comment: comment)
      assert_includes notification.content, "https://example.com/race"
      refute_includes notification.content, "[Example](https://example.com/race)"
      formatter.verify
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "duplicate execution creates only one inbox notification" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      inbox = Creative.inbox_for(creative.user)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(creative: creative, user: commenter, content: "deliver once")
      event = comment.notification_event
      clear_enqueued_jobs

      assert_difference -> { inbox.comments.count }, 1 do
        2.times { CommentNotificationJob.perform_now(comment.id, "created", event) }
      end
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "delayed placeholder creation event stays suppressed after AI completion" do
      owner = users(:one)
      agent = users(:ai_bot)
      creative = Creative.create!(user: owner, description: "Delayed Placeholder")
      topic = creative.main_topic(fallback_user: owner)
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(
        user: agent,
        topic: topic,
        content: Comment::STREAMING_PLACEHOLDER_CONTENT
      )
      event = comment.notification_event
      comment.update_column(:content, "completed response")
      clear_enqueued_jobs

      assert_no_difference -> { inbox.comments.count } do
        CommentNotificationJob.perform_now(comment.id, "created", event)
      end
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "creation event is discarded when the comment is edited before delivery" do
      owner = users(:one)
      commenter = users(:two)
      originally_mentioned = User.create!(
        email: "original-mention@example.com",
        password: TEST_PASSWORD,
        name: "OriginalMention",
        searchable: true
      )
      later_mentioned = User.create!(
        email: "later-mention@example.com",
        password: TEST_PASSWORD,
        name: "LaterMention",
        searchable: true
      )
      creative = Creative.create!(user: owner, description: "Notification Snapshot")
      original_inbox = Creative.inbox_for(originally_mentioned)
      later_inbox = Creative.inbox_for(later_mentioned)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(
        user: commenter,
        content: "Hello @#{originally_mentioned.name}: original content"
      )
      event = comment.notification_event
      comment.update!(content: "Hello @#{later_mentioned.name}: edited content")
      clear_enqueued_jobs

      assert_no_difference -> { original_inbox.comments.count } do
        assert_no_difference -> { later_inbox.comments.count } do
          CommentNotificationJob.perform_now(comment.id, "created", event)
        end
      end
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "creation event is discarded when the comment is deleted before delivery" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      inbox = Creative.inbox_for(creative.user)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(creative: creative, user: commenter, content: "deleted before delivery")
      event = comment.notification_event
      comment.destroy!
      clear_enqueued_jobs

      assert_no_difference -> { inbox.comments.count } do
        CommentNotificationJob.perform_now(comment.id, "created", event)
      end
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "delivery keys are unique per recipient" do
      owner = users(:one)
      commenter = users(:two)
      writer = User.create!(email: "second-recipient@example.com", password: TEST_PASSWORD, name: "Second Recipient")
      creative = Creative.create!(user: owner, description: "Per-recipient keys")
      CreativeShare.create!(creative: creative, user: writer, permission: :write)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(creative: creative, user: commenter, content: "notify both")
      event = comment.notification_event
      clear_enqueued_jobs

      CommentNotificationJob.perform_now(comment.id, "created", event)

      keys = [ owner, writer ].map do |recipient|
        Creative.inbox_for(recipient).comments.find_by!(quoted_comment: comment).notification_key
      end
      assert_equal keys.uniq, keys
      assert keys.all?(&:present?)
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "delivery does not lock the source comment while creating recipient notifications" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(creative: creative, user: commenter, content: "no source lock")
      event = comment.notification_event
      clear_enqueued_jobs

      comment.stub(:with_lock, ->(*) { flunk("notification delivery must not lock the source comment") }) do
        Comment.stub(:find, comment) do
          assert_difference -> { Creative.inbox_for(creative.user).comments.count }, 1 do
            CommentNotificationJob.perform_now(comment.id, "created", event)
          end
        end
      end
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "created inbox notifications do not enqueue another notification job" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(creative: creative, user: commenter, content: "single notification generation")
      event = comment.notification_event
      clear_enqueued_jobs

      CommentNotificationJob.perform_now(comment.id, "created", event)

      assert_no_enqueued_jobs only: CommentNotificationJob
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "retry broadcasts the inbox badge and enqueues push only once" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      owner = creative.user
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(creative: creative, user: commenter, content: "one set of side effects")
      event = comment.notification_event
      clear_enqueued_jobs
      inbox_badge_targets = []

      Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kwargs) {
        if args.first == [ "inbox", owner ]
          inbox_badge_targets << kwargs[:target]
        end
      }) do
        2.times { CommentNotificationJob.perform_now(comment.id, "created", event) }
      end

      assert_equal %w[desktop-inbox-badge mobile-inbox-badge], inbox_badge_targets.sort
      assert_enqueued_jobs 1, only: PushNotificationJob
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "push enqueue failure leaves a durable pending delivery for a sequential retry" do
      owner = users(:one)
      commenter = users(:two)
      creative = Creative.create!(user: owner, description: "Durable Push Retry")
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: commenter, content: "retry my push")
      event = comment.notification_event
      clear_enqueued_jobs
      enqueue_attempts = 0
      accepted_pushes = []
      successful_job = Object.new
      successful_job.define_singleton_method(:successfully_enqueued?) { true }

      PushNotificationJob.stub(:perform_later, ->(*args, **kwargs) {
        enqueue_attempts += 1
        raise ActiveJob::EnqueueError, "queue unavailable" if enqueue_attempts == 1

        accepted_pushes << [ args, kwargs ]
        successful_job
      }) do
        assert_raises ActiveJob::EnqueueError do
          comment.deliver_notifications("created", event)
        end

        delivery = CommentNotificationDelivery.find_by!(delivery_key: notification_key_for(comment, owner))
        assert_nil delivery.push_enqueued_at
        assert_nil delivery.push_claim_token
        assert_equal 1, inbox.comments.where(quoted_comment: comment).count

        comment.deliver_notifications("created", event)
        comment.deliver_notifications("created", event)
      end

      assert_equal 2, enqueue_attempts
      assert_equal 1, accepted_pushes.size
      assert_predicate(
        CommentNotificationDelivery.find_by!(delivery_key: notification_key_for(comment, owner)),
        :push_enqueued_at?
      )
      assert_equal 1, inbox.comments.where(quoted_comment: comment).count
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "push delivery sweep reclaims an expired enqueue claim" do
      owner = users(:one)
      inbox_comment = creatives(:tshirt).comments.create!(
        user: users(:two),
        content: "expired claim fixture"
      )
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
      delivery = CommentNotificationDelivery.create!(
        delivery_key: "expired-claim-#{SecureRandom.hex(4)}",
        inbox_comment_id: inbox_comment.id,
        recipient_id: owner.id,
        message: "recover this push",
        link: "/recover"
      )
      delivery.update_columns(
        push_claim_token: "abandoned",
        push_claimed_at: CommentNotificationDelivery::CLAIM_TIMEOUT.ago - 1.second
      )

      assert_enqueued_jobs 1, only: PushNotificationJob do
        CommentPushDeliverySweepJob.perform_now
      end

      assert_predicate delivery.reload, :push_enqueued_at?
      assert_nil delivery.push_claim_token
      assert_nil delivery.push_claimed_at
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "AI completion delivery remains idempotent" do
      owner = users(:one)
      agent = users(:ai_bot)
      creative = Creative.create!(user: owner, description: "AI Completion Delivery")
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(
        user: agent,
        content: Comment::STREAMING_PLACEHOLDER_CONTENT
      )
      comment.update!(content: "completed response")
      clear_enqueued_jobs

      assert_no_difference -> { inbox.comments.count } do
        assert_enqueued_with(
          job: CommentNotificationJob,
          args: [ comment.id, "ai_completion", comment.notification_event ]
        ) do
          comment.notify_ai_completion
        end
      end

      event = comment.notification_event
      clear_enqueued_jobs
      assert_difference -> { inbox.comments.count }, 1 do
        2.times { CommentNotificationJob.perform_now(comment.id, "ai_completion", event) }
      end
      assert_enqueued_jobs 1, only: PushNotificationJob
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "delivers approver notifications in the background" do
      owner = users(:one)
      agent = users(:ai_bot)
      creative = Creative.create!(user: owner, description: "Approval Delivery")
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(
        user: agent,
        approver: owner,
        action: { tool_name: "Bash", action: "approve_tool" }.to_json,
        content: "Approve Bash",
        private: true
      )
      event = comment.notification_event
      clear_enqueued_jobs

      assert_difference -> { inbox.comments.count }, 1 do
        CommentNotificationJob.perform_now(comment.id, "created", event)
      end

      notification = inbox.comments.find_by!(quoted_comment: comment)
      assert_includes notification.content, "Bash"
      assert_match(/approver/, notification.notification_key)
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    private

    def notification_key_for(comment, recipient)
      "comment:#{comment.id}:#{comment.notification_revision}:created:write:recipient:#{recipient.id}"
    end
  end

  class CommentNotificationConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    test "concurrent retries create and push one notification" do
      creative = creatives(:tshirt)
      commenter = users(:two)
      owner = creative.user
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = Comment.create!(
        creative: creative,
        user: commenter,
        content: "concurrent delivery"
      )
      source_topic = comment.topic
      event = comment.notification_event
      clear_enqueued_jobs

      ready = Queue.new
      release = Queue.new
      errors = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            CommentNotificationJob.perform_now(comment.id, "created", event)
          end
        rescue StandardError => e
          errors << e
        end
      end

      2.times { ready.pop }
      2.times { release << true }
      threads.each(&:join)

      assert errors.empty?, -> {
        error = errors.pop
        "concurrent delivery failed: #{error.class}: #{error.message}"
      }
      assert_equal 1, inbox.comments.where(quoted_comment: comment).count
      assert_enqueued_jobs 1, only: PushNotificationJob
    ensure
      clear_enqueued_jobs
      CommentNotificationDelivery.where("delivery_key LIKE ?", "comment:#{comment&.id}:%").delete_all
      comment&.destroy!
      source_topic&.destroy!
      inbox&.destroy!
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "concurrent enqueue failure remains pending and the sweep retry enqueues one push" do
      owner = User.create!(
        email: "push-owner-#{SecureRandom.hex(4)}@example.com",
        password: TEST_PASSWORD,
        name: "Push Owner"
      )
      commenter = User.create!(
        email: "push-commenter-#{SecureRandom.hex(4)}@example.com",
        password: TEST_PASSWORD,
        name: "Push Commenter"
      )
      creative = Creative.create!(user: owner, description: "Concurrent Push Retry")
      inbox = Creative.inbox_for(owner)
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: commenter, content: "concurrent failed push")
      event = comment.notification_event
      clear_enqueued_jobs
      first_enqueue_started = Queue.new
      release_first_enqueue = Queue.new
      errors = Queue.new
      accepted_pushes = Queue.new
      attempts_lock = Mutex.new
      enqueue_attempts = 0
      successful_job = Object.new
      successful_job.define_singleton_method(:successfully_enqueued?) { true }

      PushNotificationJob.stub(:perform_later, ->(*args, **kwargs) {
        attempt = attempts_lock.synchronize do
          enqueue_attempts += 1
        end

        if attempt == 1
          first_enqueue_started << true
          release_first_enqueue.pop
          raise ActiveJob::EnqueueError, "queue unavailable"
        end

        accepted_pushes << [ args, kwargs ]
        successful_job
      }) do
        first = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            comment.reload.deliver_notifications("created", event)
          end
        rescue StandardError => e
          errors << e
        end

        first_enqueue_started.pop
        second = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            comment.reload.deliver_notifications("created", event)
          end
        rescue StandardError => e
          errors << e
        end
        second.join
        release_first_enqueue << true
        first.join

        delivery = CommentNotificationDelivery.find_by!(
          delivery_key: notification_key_for(comment, owner)
        )
        assert_nil delivery.push_enqueued_at

        CommentPushDeliverySweepJob.perform_now
        CommentPushDeliverySweepJob.perform_now
      end

      assert_equal 1, errors.size
      assert_instance_of ActiveJob::EnqueueError, errors.pop
      assert_equal 2, enqueue_attempts
      assert_equal 1, accepted_pushes.size
      assert_equal 1, inbox.comments.where(quoted_comment: comment).count
      assert_predicate(
        CommentNotificationDelivery.find_by!(delivery_key: notification_key_for(comment, owner)),
        :push_enqueued_at?
      )
    ensure
      clear_enqueued_jobs
      CommentNotificationDelivery.where(recipient_id: owner&.id).delete_all
      comment&.destroy!
      creative&.destroy!
      inbox&.destroy!
      commenter&.destroy!
      owner&.destroy!
      ActiveJob::Base.queue_adapter = original_adapter
    end

    private

    def notification_key_for(comment, recipient)
      "comment:#{comment.id}:#{comment.notification_revision}:created:write:recipient:#{recipient.id}"
    end
  end
end

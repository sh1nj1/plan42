require "test_helper"

# Marking read is on the interactive path: every topic switch and every All
# Messages visit hits it. On a networked database the cost is dominated by round
# trips, not by any single statement, so these ceilings guard the query *count*
# rather than wall-clock time.
class CommentReadPointersQueryCountTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    @creative = creatives(:tshirt)
  end

  # The regression this guards: marking All Messages read used to cost roughly
  # 14 extra queries per rendered topic (10 topics = 188), because each topic
  # resolved its own maximum, took its own lock, and broadcast its own receipts.
  test "All Messages read cost does not grow per rendered topic" do
    count_queries_for_all_messages(topic_count: 1) # session/locale warm-up
    five_topics = count_queries_for_all_messages(topic_count: 5)
    twenty_topics = count_queries_for_all_messages(topic_count: 20)

    assert_equal five_topics, twenty_topics,
      "expected a flat query count, got #{five_topics} for 5 topics and #{twenty_topics} for 20"
  end

  test "switching to a single topic stays well under the per-topic era" do
    topic = @creative.topics.create!(name: "Switch", user: @user)
    Comment.create!(creative: @creative, topic: topic, user: users(:two), content: "hi")

    count = count_queries do
      post "/comment_read_pointers/update",
        params: { creative_id: @creative.id, topic_id: topic.id }, as: :json
    end

    assert_response :success
    # ~8 of these are session/authentication overhead outside this controller.
    assert_operator count, :<=, 26, "topic switch took #{count} queries"
  end

  private

  def count_queries_for_all_messages(topic_count:)
    creative = Creative.create!(description: "Perf #{topic_count}", user: @user)
    topics = Array.new(topic_count) do |index|
      creative.topics.create!(name: "Topic #{index}", user: @user)
    end
    watermarks = topics.to_h do |topic|
      comment = Comment.create!(creative: creative, topic: topic, user: users(:two), content: "hi")
      [ topic.id.to_s, comment.id.to_s ]
    end

    count = count_queries do
      post "/comment_read_pointers/update",
        params: {
          creative_id: creative.id,
          topic_ids: topics.map(&:id),
          topic_watermarks: watermarks
        }, as: :json
    end
    assert_response :success
    count
  end

  # SAVEPOINT/RELEASE are round trips too, so they are counted rather than
  # filtered out: removing per-row locking is the point of the ceiling.
  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].start_with?("PRAGMA")
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

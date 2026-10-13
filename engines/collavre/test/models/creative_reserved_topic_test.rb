require "test_helper"

class CreativeReservedTopicTest < ActiveSupport::TestCase
  setup do
    @creative = Collavre::Creative.create!(user: users(:one), description: "Reserved topics")
    @creative.topics.destroy_all
  end

  %i[main_topic system_topic].each do |method|
    test "#{method} creates and reuses a topic with the fallback owner" do
      topic = @creative.public_send(method, fallback_user: users(:two))
      assert_equal users(:two), topic.user
      assert_equal topic, @creative.public_send(method)
    end

    [ ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique ].each do |error_class|
      test "#{method} recovers when concurrent creation raises #{error_class}" do
        association = @creative.topics
        winner = nil
        original_find = association.method(:find_by)
        original_create = association.method(:create!)
        competing_find = lambda do |attributes|
          if winner
            original_find.call(attributes)
          else
            winner = original_create.call(attributes.merge(user: users(:one)))
            nil
          end
        end
        losing_create = lambda do |attributes|
          if error_class == ActiveRecord::RecordInvalid
            original_create.call(attributes)
          else
            raise ActiveRecord::RecordNotUnique
          end
        end
        association.stub :find_by, competing_find do
          association.stub :create!, losing_create do
            result = @creative.public_send(method)
            assert_equal winner, result
          end
        end
        assert_equal 1, association.where(name: winner.name).count
      end
    end

    test "#{method} preserves validation failures without a concurrent topic" do
      invalid = Collavre::Topic.new
      error = ActiveRecord::RecordInvalid.new(invalid)
      @creative.topics.stub :create!, ->(*) { raise error } do
        assert_same error, assert_raises(ActiveRecord::RecordInvalid) { @creative.public_send(method) }
      end
    end
  end
end

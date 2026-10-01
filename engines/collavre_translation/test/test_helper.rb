require_relative "../../../test/test_helper"

module TranslationQueueTestHelper
  def use_translation_test_queue
    @translation_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  def restore_translation_queue
    ActiveJob::Base.queue_adapter = @translation_queue_adapter
  end
end

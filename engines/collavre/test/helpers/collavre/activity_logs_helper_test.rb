# frozen_string_literal: true

require "test_helper"

class Collavre::ActivityLogsHelperTest < ActionView::TestCase
  include Collavre::ActivityLogsHelper

  test "formats English durations with seconds minutes and hours" do
    I18n.with_locale(:en) do
      { 0 => "0s", 0.1 => "0s", 0.6 => "1s", 59.5 => "1m", 60 => "1m", 83 => "1m 23s",
        3600 => "1h", 3661 => "1h 1m 1s", 90000 => "25h" }.each do |seconds, text|
        assert_equal text, format_execution_time(seconds)
      end
    end
  end

  test "formats Korean durations" do
    I18n.with_locale(:ko) do
      assert_equal "0초", format_execution_time(0)
      assert_equal "1분 23초", format_execution_time(83)
      assert_equal "1시간 1분 1초", format_execution_time(3661)
    end
  end

  test "renders task states and measured duration" do
    task = Collavre::Task.new(status: "running")
    I18n.with_locale(:en) do
      assert_equal "In progress", task_execution_time(task)
      task.status = "done"
      Collavre::TaskExecutionTime.stub(:seconds, nil) do
        assert_equal "Unavailable", task_execution_time(task)
      end
      Collavre::TaskExecutionTime.stub(:seconds, 83) do
        assert_equal "1m 23s", task_execution_time(task)
      end
    end
  end
end

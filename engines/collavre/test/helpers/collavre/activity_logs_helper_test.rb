# frozen_string_literal: true

require "test_helper"

class Collavre::ActivityLogsHelperTest < ActionView::TestCase
  include Collavre::ActivityLogsHelper

  test "localizes known activities and unknown keys in both languages" do
    { en: [ "Model request", "Tool execution", "Agent activity" ], ko: [ "모델 요청", "도구 실행", "에이전트 활동" ] }.each do |locale, labels|
      I18n.with_locale(locale) do
        %w[llm_query tool_execution future_event].zip(labels).each do |key, label|
          assert_equal label, activity_log_name(key)
        end
      end
    end
  end

  test "formats English durations with seconds minutes and hours" do
    I18n.with_locale(:en) do
      { 0 => "0s", 0.1 => "0s", 0.6 => "1s", 59.5 => "1m", 60 => "1m", 83 => "1m 23s",
        3600 => "1h", 3661 => "1h 1m 1s", 86400 => "1d", 90000 => "1d 1h", 90061 => "1d 1h 1m 1s" }.each do |seconds, text|
        assert_equal text, format_execution_time(seconds)
      end
    end
  end

  test "formats Korean durations" do
    I18n.with_locale(:ko) do
      assert_equal "0초", format_execution_time(0)
      assert_equal "1분 23초", format_execution_time(83)
      assert_equal "1시간 1분 1초", format_execution_time(3661)
      assert_equal "1일 1시간 1분 1초", format_execution_time(90061)
    end
  end

  test "inline timing only formats measured durations including zero" do
    assert_nil inline_task_execution_time(nil)
    task = Collavre::Task.new(status: "running")
    assert_nil inline_task_execution_time(task)
    task.status = "done"
    I18n.with_locale(:en) do
      Collavre::TaskExecutionTime.stub(:seconds, nil) { assert_nil inline_task_execution_time(task) }
      Collavre::TaskExecutionTime.stub(:seconds, 0) { assert_equal "0s", inline_task_execution_time(task) }
      Collavre::TaskExecutionTime.stub(:seconds, 83) { assert_equal "1m 23s", inline_task_execution_time(task) }
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "rake"

# `rake clean` is a development convenience that resets regenerable local
# artifacts (most importantly clobbering public/assets so a stale Propshaft
# .manifest.json can't force the Static resolver into MissingAssetError).
# It must refuse to run in production, where public/assets is the real
# precompiled output.
class CleanTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("clean")
    Rake::Task["clean"].reenable
  end

  test "clean task is defined" do
    assert Rake::Task.task_defined?("clean")
  end

  test "refuses to run in production" do
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      assert_raises(SystemExit) { Rake::Task["clean"].invoke }
    end
  end

  test "in development invokes assets:clobber, tmp:clear and log:clear in order" do
    invoked = []
    clobber = Rake::Task["assets:clobber"]
    tmp = Rake::Task["tmp:clear"]
    log = Rake::Task["log:clear"]

    clobber.stub(:invoke, ->(*) { invoked << "assets:clobber" }) do
      tmp.stub(:invoke, ->(*) { invoked << "tmp:clear" }) do
        log.stub(:invoke, ->(*) { invoked << "log:clear" }) do
          Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
            Rake::Task["clean"].invoke
          end
        end
      end
    end

    assert_equal %w[assets:clobber tmp:clear log:clear], invoked
  end
end

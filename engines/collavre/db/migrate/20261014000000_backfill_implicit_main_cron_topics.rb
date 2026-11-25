# frozen_string_literal: true

class BackfillImplicitMainCronTopics < ActiveRecord::Migration[8.0]
  include Collavre::Crons::RecurringTaskArguments

  # Recurring tasks may live in a separate queue database. Use their model's
  # connection and lock each row independently of the primary migration.
  def up
    return unless SolidQueue::RecurringTask.table_exists?

    SolidQueue::RecurringTask.where(static: false, class_name: "Collavre::CronActionJob").find_each do |task|
      task.with_lock { backfill_task(task) }
    rescue ActiveRecord::RecordNotFound
      # A concurrently cancelled task requires no backfill.
      next
    end
  end

  def down
    # Explicit topic identities must survive rollback to avoid retargeting jobs.
  end

  private

  def backfill_task(task)
    args = parse_arguments(task)
    return if args.empty? || args["topic_id"].present?

    creative_id = args["creative_id"].presence || parse_creative_id_from_key(task.key)
    creative = Collavre::Creative.find_by(id: creative_id)&.effective_origin
    main = creative&.topics&.find_by(name: Collavre::Creative::MAIN_TOPIC_NAME)
    return unless main

    args["topic_id"] = main.id
    args["creative_id"] = creative_id if args["creative_id"].blank?
    task.update!(arguments: [ args, *task.arguments.drop(1) ])
  end
end

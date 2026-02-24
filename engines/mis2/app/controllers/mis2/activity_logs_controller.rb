module Mis2
  class ActivityLogsController < Mis2::ApplicationController
    include Mis2::Paginatable

    def index
      scope = Mis2::ActivityLog.order(created_at: :desc)
      @logs = paginate(scope)
    end

    def show
      @log = Mis2::ActivityLog.find(params[:id])
    end

    def undo
      @log = Mis2::ActivityLog.find(params[:id])

      unless @log.undoable?
        redirect_to mis2.activity_logs_path, alert: t("mis2.activity_logs.undo.not_undoable")
        return
      end

      @log.undo!(performed_by: Current.user)
      redirect_to mis2.activity_logs_path, notice: t("mis2.activity_logs.undo.success")
    rescue ActiveRecord::RecordNotFound => e
      redirect_to mis2.activity_logs_path, alert: t("mis2.activity_logs.undo.error", message: e.message)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, RuntimeError => e
      Rails.logger.error("[Undo] log_id=#{params[:id]} error=#{e.class}: #{e.message}")
      redirect_to mis2.activity_logs_path, alert: t("mis2.activity_logs.undo.error", message: e.message)
    end
  end
end

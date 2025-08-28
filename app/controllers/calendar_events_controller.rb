class CalendarEventsController < ApplicationController
  def destroy
    event = CalendarEvent.where(user: Current.user).find(params[:id])
    event.destroy
    respond_to do |format|
      format.html do
        redirect_back fallback_location: root_path,
                      notice: t('calendar_events.deleted', default: 'Event deleted.')
      end
      format.json { head :no_content }
    end
  end
end

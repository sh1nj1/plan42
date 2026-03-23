module Collavre
class TopicsChannel < ApplicationCable::Channel
  def subscribed
    return reject unless params[:creative_id].present? && current_user

    @creative = Creative.find(params[:creative_id]).effective_origin
    return reject unless @creative.has_permission?(current_user, :read)

    stream_for @creative
    # User-specific stream for preference sync (e.g. last_topic_changed)
    stream_for "user_#{current_user.id}_creative_#{@creative.id}"
  end
end
end

class SlideViewChannel < ApplicationCable::Channel
  def subscribed
    stream_for [ current_user.id, params[:root_id] ]
  end

  def change(data)
    SlideViewChannel.broadcast_to([ current_user.id, params[:root_id] ], index: data["index"])
  end
end

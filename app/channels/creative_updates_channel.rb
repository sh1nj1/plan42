class CreativeUpdatesChannel < ApplicationCable::Channel
  def subscribed
    reject unless current_user
    stream_for current_user
  end
end

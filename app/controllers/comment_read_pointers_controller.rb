class CommentReadPointersController < ApplicationController
  def update
    creative = Creative.find(params[:creative_id]).effective_origin
    last_id = creative.comments.maximum(:id)
    pointer = CommentReadPointer.find_or_initialize_by(user: Current.user, creative: creative)
    pointer.last_read_comment_id = last_id
    pointer.save!
    render json: { success: true }
  end
end

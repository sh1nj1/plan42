class CreativeSharesController < ApplicationController
  def create
    @creative = Creative.find(params[:creative_id]).effective_origin
    user = User.find_by(email: params[:user_email])
    unless user
      invitation = Invitation.create!(email: params[:user_email], inviter: Current.user, creative: @creative, permission: params[:permission])
      InvitationMailer.with(invitation: invitation).invite.deliver_later
      flash[:notice] = t("invites.invite_sent")
      redirect_back(fallback_location: creatives_path) and return
    end

    permission = params[:permission]

    ancestor_ids = @creative.ancestors.pluck(:id)
    existing_high_share = CreativeShare.where(creative_id: ancestor_ids, user: user)
      .where("permission >= ?", CreativeShare.permissions[permission])
      .exists?

    unless existing_high_share
      share = CreativeShare.find_or_initialize_by(creative: @creative, user: user)
      share.permission = permission
      if share.save
        @creative.create_linked_creative_for_user(user)
        flash[:notice] = t("creatives.share.shared")
      else
        flash[:alert] = share.errors.full_messages.to_sentence
      end
    else
      flash[:alert] = t("creatives.share.already_shared_in_parent")
    end
    redirect_back(fallback_location: creatives_path)
  end

  def destroy
    @creative_share = CreativeShare.find(params[:id])
    @creative_share.destroy
    # remove linked creative if it exists
    linked_creative = Creative.find_by(origin_id: @creative_share.creative_id, user_id: @creative_share.user_id)
    linked_creative&.destroy
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, notice: t("creatives.index.share_deleted") }
      format.json { head :no_content }
    end
  end

  private

    def all_descendants(creative)
      creative.children.flat_map { |child| [ child ] + all_descendants(child) }
    end
end

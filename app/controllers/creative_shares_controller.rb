class CreativeSharesController < ApplicationController
  def index
    creative = Creative.find(params[:creative_id])
    shares = creative.creative_shares.includes(:user)
    render json: shares.map { |s| share_json(s) }
  end

  def create
    @creative = Creative.find(params[:creative_id]).effective_origin
    user = User.find_by(email: params[:user_email])
    respond_to do |format|
      unless user
        invitation = Invitation.create!(email: params[:user_email], inviter: Current.user, creative: @creative, permission: params[:permission])
        InvitationMailer.with(invitation: invitation).invite.deliver_later
        format.html do
          flash[:notice] = t("invites.invite_sent")
          redirect_back(fallback_location: creatives_path)
        end
        format.json { render json: { invited: true, message: t("invites.invite_sent") } }
        return
      end

    permission = params[:permission]

    ancestor_ids = @creative.ancestors.pluck(:id)
    ancestor_shares = CreativeShare.where(creative_id: ancestor_ids, user: user)
                                   .where("permission >= ? or permission = ?", CreativeShare.permissions[permission], CreativeShare.permissions[:no_access])
    closest_parent_share = CreativeShare.closest_parent_share(ancestor_ids, ancestor_shares)

    is_param_no_access = permission == :no_access.to_s
    Rails.logger.debug "### closest_parent_share = #{closest_parent_share.inspect}, is_param_no_access: #{is_param_no_access}"
    if closest_parent_share.present?
      msg = if closest_parent_share.permission == :no_access.to_s
              t("creatives.share.can_not_share_by_no_access_in_parent")
      elsif !is_param_no_access
              t("creatives.share.already_shared_in_parent")
      end
      if msg
        format.html do
          flash[:alert] = msg
          redirect_back(fallback_location: creatives_path)
        end
        format.json { render json: { error: msg }, status: :unprocessable_entity }
        return
      end
    end

    share = CreativeShare.find_or_initialize_by(creative: @creative, user: user)
    share.permission = permission
    if share.save && !is_param_no_access
      @creative.create_linked_creative_for_user(user)
      format.html { flash[:notice] = t("creatives.share.shared") }
      format.json { render json: share_json(share), status: :created }
    elsif share.errors.any?
      format.html { flash[:alert] = share.errors.full_messages.to_sentence }
      format.json { render json: { error: share.errors.full_messages.to_sentence }, status: :unprocessable_entity }
    else
      format.html { }
      format.json { render json: share_json(share), status: :ok }
    end
    format.html { redirect_back(fallback_location: creatives_path) }
  end
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

    def share_json(share)
      {
        id: share.id,
        user_name: share.user&.display_name || t("creatives.index.unknown_user"),
        permission: share.permission,
        permission_name: t("creatives.index.permission_#{share.permission}"),
        creative: {
          id: share.creative_id,
          title: ActionController::Base.helpers.strip_tags(share.creative.effective_description),
          link: Rails.application.routes.url_helpers.creative_path(share.creative)
        },
        created_at: share.created_at
      }
    end
end

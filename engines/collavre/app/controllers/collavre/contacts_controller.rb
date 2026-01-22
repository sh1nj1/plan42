module Collavre
  class ContactsController < ApplicationController
    def destroy
      contact = Current.user.contacts.find(params[:id])
      contact.destroy
      redirect_to main_app.user_path(Current.user, tab: "contacts", contact_page: params[:contact_page]),
                  notice: t("contacts.notices.removed")
    end
  end
end

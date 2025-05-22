class CreativeMailer < ApplicationMailer
  # Subject can be set in your I18n file at config/locales/en.yml
  # with the following lookup:
  #
  #   en.creative_mailer.in_stock.subject
  #
  def in_stock
    @creative = params[:creative]
    mail to: params[:subscriber].email
  end
end

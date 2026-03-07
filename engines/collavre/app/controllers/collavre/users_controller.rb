module Collavre
  class UsersController < ApplicationController
    include UsersController::Registration
    include UsersController::AiUserManagement
    include UsersController::ContactManagement
    include UsersController::AdminOperations
    include UsersController::ProfileAndSettings
  end
end

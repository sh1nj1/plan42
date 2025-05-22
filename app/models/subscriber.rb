class Subscriber < ApplicationRecord
  belongs_to :creative
  generates_token_for :unsubscribe
end

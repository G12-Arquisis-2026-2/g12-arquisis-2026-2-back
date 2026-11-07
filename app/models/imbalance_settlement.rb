class ImbalanceSettlement < ApplicationRecord
  validates :idpk, :msg_id, :cycle_id, :settlement_id, presence: true
end

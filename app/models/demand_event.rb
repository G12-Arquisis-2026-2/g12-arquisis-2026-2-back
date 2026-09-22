class DemandEvent < ApplicationRecord
    validates :idpk, presence: true, uniqueness: true
    validates :event_type, :package_body, :received_at, presence: true
  end

module Spree
  Order.class_eval do
    validates :retailops_import, inclusion: { in: [ 'yes', 'no', 'done' ] }
  end
end

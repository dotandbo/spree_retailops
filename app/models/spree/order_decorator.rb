module Spree
  Order.class_eval do
    validates :retailops_import, inclusion: { in: [ 'yes', 'no', 'done' ] }
  end
  Order.state_machine.before_transition :to => :complete do |order|
    order.retailops_import = Spree::Config[:retailops_import_by_default] ? 'yes' : 'no'
  end
end

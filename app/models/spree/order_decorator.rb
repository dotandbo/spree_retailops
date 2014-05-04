module Spree
  Order.class_eval do
    validates :retailops_import, inclusion: { in: [ 'yes', 'no', 'done' ] }
    before_validation on: :create do
      self.retailops_import = Spree::Config[:retailops_import_by_default] ? 'yes' : 'no'
    end
  end
end

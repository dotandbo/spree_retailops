Spree::AppConfiguration.class_eval do
  preference :retailops_import_by_default, :boolean, default: true
  preference :retailops_express_shipping_price, :string, default: 'cost'
end

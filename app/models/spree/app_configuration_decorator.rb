Spree::AppConfiguration.class_eval do
  preference :retailops_import_by_default, :boolean, default: false
end

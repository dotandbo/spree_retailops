class AddRetailopsImportToSpreeOrders < ActiveRecord::Migration
  def change
    add_column :spree_orders, :retailops_import, :string, { default: 'yes' }
    add_index  :spree_orders, [ :retailops_import ]
  end
end

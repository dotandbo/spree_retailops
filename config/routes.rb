Spree::Core::Engine.routes.draw do
  namespace :retailops do
    post 'catalog', to: 'catalog#catalog_push'
    post 'inventory', to: 'inventory#inventory_push'

    get 'orders', to: 'orders#index'
    post 'orders/mark_exported', to: 'orders#export'
    # TODO: order settlement
  end
end

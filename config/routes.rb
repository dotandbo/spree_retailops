Spree::Core::Engine.routes.draw do
  namespace :retailops do
    post 'catalog', to: 'catalog#catalog_push'
    post 'inventory', to: 'inventory#inventory_push'

    get 'orders', to: 'orders#index'
    post 'orders/mark_exported', to: 'orders#export'
    # TODO: order settlement
  end

  namespace :admin do
    resource :retailops_integration_settings, :only => ['update', 'edit']
  end

  namespace :api do
    put 'orders/:id/retailops_importable', to: 'orders#retailops_importable'
  end
end

Spree::Core::Engine.routes.draw do
  namespace :retailops do
    post 'catalog', to: 'catalog#catalog_push'
    post 'inventory', to: 'inventory#inventory_push'
    resources :orders, only: [:show, :index] do
      post 'mark_exported', to: 'orders#export'
      post 'completed', to: 'orders#completed'
      post 'cancelled', to: 'orders#cancelled'
      post 'refunded', to: 'orders#refunded'
    end
  end
end

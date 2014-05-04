Spree::Api::OrdersController.class_eval do
  def retailops_importable
    find_order
    authorize! :update, @order
    if @order.retailops_import != 'done'
      @order.retailops_import = params["importable"].to_s
      @order.save!
    end
    render text: {}.to_json
  end
end

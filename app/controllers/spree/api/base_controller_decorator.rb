Spree::Api::BaseController.class_eval do
  def log_request
    logger.info request.env
  end
end


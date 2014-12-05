class Spree::Retailops::CatalogPushJob# < ActiveJob::Base
  include Spree::Retailops::CatalogHelper
  #queue_as :default

  attr_reader :params

  def initialize
    @params = {}
    @diag, @memo, @failed = [], {}, {}
  end

  def perform(products, params = {})
    @params = params

    products.to_a.each {|product| upsert_product_and_variants(product)}

    # Spree::Api::Ratailops.catalog_push_results(@diag)
  end
end

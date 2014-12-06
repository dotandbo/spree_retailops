class Spree::Retailops::CatalogPushJob < ActiveJob::Base
  include Spree::Retailops::CatalogHelper
  queue_as :default

  attr_reader :params

  def perform(products, params = {})
    @params, @diag, @memo, @failed = [], {}, {}, params

    products.to_a.each {|product| upsert_product_and_variants(product)}

    # upload_catalog_push_results(@diag)
  end
end

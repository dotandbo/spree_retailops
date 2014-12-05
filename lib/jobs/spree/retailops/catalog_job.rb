class Spree::Retailops::CatalogJob < ActiveJob::Base
  queue_as :default

  attr_reader :params

  def initialize
    @params = {}
    @diag   = []
    @memo   = {}
    @failed = {}
  end

  def perform(products, params = {})
    @params = params

    products.to_a.each { |pd| upsert_product_and_variants(pd) }

    # Spree::Api::Ratailops.import_results(@diag)
  end

  private
    include Spree::Api::Retailops::CatalogHelpers
end

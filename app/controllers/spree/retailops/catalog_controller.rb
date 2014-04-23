module Spree
  module Retailops
    class CatalogController < Spree::Api::BaseController
      def catalog_push
        # actually a lot more privs maybe?
        authorize! :create, Product
        authorize! :update, Product

        params["products"].isa? Array or throw "products must be array"

        @diag = []
        params["products"].each { |p| upsert_product p }

        render json: { "import_results" => @diag }
      end

      private
        def add_error(msg)
          @diag << { "corr_id" => @current_corr_id, "message" => msg, "failed" => true }
        end

        def add_warn(msg)
          @diag << { "corr_id" => @current_corr_id, "message" => msg }
        end

        def upsert_product(p)
          @current_corr_id = p["corr_id"]

          return add_error("no variants specified") if p["variants"].empty?
          # in the non-varying case, copy data up
          if p["options"].empty?
            v = p["variants"][0]
            p["variants"] = []
            %w( images tax_category weight height depth width cost_price price cost_currency sku ).each do |c|
              p[c] = v[c] if v.has_key?(c)
            end
          end

          return add_error("sku not specified") if !p["sku"]
          ex_master_variant = Variant.find_by(sku: p["sku"], is_master: true)
          product = ex_master_variant && ex_master_variant.product

          unless product
            product = Product.new
          end

          ...

          upsert_variant(product, product.master_variant, p)

          p["variants"].each { |v| upsert_variant(product, nil, v) }
        end

        def upsert_variant(product, variant, v)
          @current_corr_id = v["corr_id"]

          unless variant
            ...
          end

          ...
        end
    end
  end
end

require_dependency 'spree/calculator'

module Spree
  module Calculator::Shipping
    class RetailopsAdvisory < ShippingCalculator
      def self.description
        Spree.t(:retailops_advisory_ship_calculator)
      end

      def available?(package)
        false
      end
    end
  end
end

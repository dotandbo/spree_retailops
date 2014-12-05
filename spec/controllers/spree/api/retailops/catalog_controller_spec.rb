require 'spec_helper'

describe Spree::Api::Retailops::CatalogController, :type => :controller do
  before do
    stub_authentication!
    @ability = Object.new
    @ability.extend(CanCan::Ability)
    @controller.stub(:current_ability).and_return(@ability)
  end

  it "post catalog_push" do
    @ability.can :create, Spree::Product
    @ability.can :update, Spree::Product
    api_post :catalog_push, :products => []
    response.should be_success
  end

end
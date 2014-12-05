require 'spec_helper'

describe Spree::Api::Retailops::CatalogController, :type => :controller do
  before do
    stub_authentication!
  end

  it "post catalog_push" do
    api_post :catalog_push
    response.should be_success
  end

end
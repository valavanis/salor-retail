require 'spec_helper'

describe "invoice_blurbs/new" do
  before(:each) do
    assign(:invoice_blurb, stub_model(InvoiceBlurb,
      :lang => "MyString",
      :body => "MyText",
      :is_header => false
    ).as_new_record)
  end

  it "renders new invoice_blurb form" do
    render

    # Run the generator again with the --webrat flag if you want to use webrat matchers
    assert_select "form", :action => invoice_blurbs_path, :method => "post" do
      assert_select "input#invoice_blurb_lang", :name => "invoice_blurb[lang]"
      assert_select "textarea#invoice_blurb_body", :name => "invoice_blurb[body]"
      assert_select "input#invoice_blurb_is_header", :name => "invoice_blurb[is_header]"
    end
  end
end
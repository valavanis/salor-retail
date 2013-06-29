# coding: UTF-8

# Salor -- The innovative Point Of Sales Software for your Retail Store
# Copyright (C) 2012-2013  Red (E) Tools LTD
# 
# See license.txt for the license applying to all files within this software.

class DrawerTransaction < ActiveRecord::Base
  # {START}
  include SalorBase
  include SalorScope
  include SalorModel
  belongs_to :vendor
  belongs_to :drawer
  belongs_to :cash_register
  
  belongs_to :current_register
  
  belongs_to :user
  belongs_to :order
  
  def trans_type=(x)
    if x == 'drop' then
      self.drop = true
    else
      self.payout = true
    end
  end
  
  def amount=(p)
    write_attribute(:amount,self.string_to_float(p))
  end

  def print
    if @current_register.id
      vendor_printer = VendorPrinter.new :path => @current_register.thermal_printer
      text = self.escpos
      print_engine = Escper::Printer.new('local', vendor_printer)
      print_engine.open
      print_engine.print(0, text)
      print_engine.close
      Receipt.create(:user_id => @User.id, :current_register_id => @current_register.id, :content => text)
    end
  end
  
  def escpos
    init = 
    "\e@"     +  # Initialize Printer
    "\x1B\x70\x00\x30\x01" + # open cash drawer early
    "\ea\x01" +  # align center
    "\e!\x38" +
    DrawerTransaction.model_name.human + ' ' +
    self.id.to_s +
    "\n\n" +
    "\e!\x01" +
    I18n.l(self.created_at, :format => :long) +
    "\n\n" +
    "\e!\x38" +
    @current_user.username +
    "\n\n" +
    self.tag +
    "\n\n" +
    self.notes +
    "\n\n" +
    "\e!\x38" +
    SalorBase.to_currency(self.amount) +
    "\n\n" +
    I18n.t(self.drop ? 'printr.word.drop' : 'printr.word.payout') +
    "\n\n\n\n\n\n\n" +
    "\x1D\x56\x00" # cut
    
    #GlobalData.vendor.receipt_logo_footer 
  end
  
  def self.check_range(from_to)
    messages = []
    dts = DrawerTransaction.where(:created_at => from..to)
    1.upto(dts.size-1).each do |i|
        if dts[i-1].payout
            factor = -1
        else
            factor = 1
        end
        
        if dts[i].drawer_amount.round(2) == (dts[i-1].drawer_amount + dts[i-1].amount * factor).round(2)
            messages << ""
        else
            messages << "#{dts[i].id} not ok: #{dts[i].drawer_amount.round(2)} #{(dts[i-1].drawer_amount + dts[i-1].amount * factor).round(2)}"
        end
    end
    puts messages.inspect
  end
  # {END}
end

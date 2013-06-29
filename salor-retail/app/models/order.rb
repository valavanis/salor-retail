# coding: UTF-8

# Salor -- The innovative Point Of Sales Software for your Retail Store
# Copyright (C) 2012-2013  Red (E) Tools LTD
# 
# See license.txt for the license applying to all files within this software.

class Order < ActiveRecord::Base
 # {START}
	include SalorScope
  include SalorBase

  has_many :order_items
  has_many :payment_methods
  has_many :paylife_structs
  has_many :histories, :as => :model
  has_many :drawer_transactions
  has_one :receipt
  belongs_to :user
  belongs_to :company
  belongs_to :customer
  belongs_to :vendor
  belongs_to :cash_register
  belongs_to :current_register_daily
  belongs_to :drawer

  belongs_to :origin_country, :class_name => 'Country', :foreign_key => 'origin_country_id'
  belongs_to :destination_country, :class_name => 'Country', :foreign_key => 'destination_country_id'
  belongs_to :sale_type
  
  has_and_belongs_to_many :discounts
  scope :last_seven_days, lambda { where(:created_at => 7.days.ago.utc...Time.now.utc) }
  scope :unpaid, lambda { 
    t = self.table_name
    where(" ( ( `#{t}`.paid IS NULL OR `#{t}`.paid = 0) AND ( `#{t}`.total > 0.0 AND `#{t}`.total IS NOT NULL )  OR  ( `#{t}`.paid = 1 AND `#{t}`.unpaid_invoice IS TRUE) )").where(:is_quote => false) 
  }
  scope :normal_orders, lambda {
      where(:is_quote => false, :is_proforma => false)
  }
  scope :normal_completed, lambda {
      normal_orders.where(:paid => 1)
  }
  scope :quotes, lambda {
    where(:is_quote => true, :paid => 1)
  }
  
  # These two associations are here for eager loading to speed things up
  has_many :coupons, :class_name => "OrderItem", :conditions => "behavior = 'coupon' and hidden != 1" 
  has_many :gift_cards, :class_name => "OrderItem", :conditions => "behavior = 'gift_card' and hidden != 1"

  I18n.locale = AppConfig.locale
  REBATE_TYPES = [
    [I18n.t('views.forms.percent_off'),'percent'],
    [I18n.t('views.forms.fixed_amount_off'),'fixed']
  ]
  def as_csv
    return attributes
  end
  def amount_paid
    self.payment_methods.sum(:amount)
  end
  def nonrefunded_item_count
    self.order_items.visible.where(:refunded => false).count
  end

  def has_cute_credit_message?
    config = ActiveRecord::Base.configurations[Rails.env].symbolize_keys
    conn = Mysql2::Client.new(config)
    sql = "SELECT count(*) as num FROM cute_credit.cute_credit_messages where ref_id = '#{self.id}'"
    cnt = conn.query(sql).first
    if cnt then
      num = cnt["num"]
    else
      num = 0
    end
    if num > 0 then
      return true
    else
      return false
    end
  end
  def cute_credit_message
    config = ActiveRecord::Base.configurations[Rails.env].symbolize_keys
    conn = Mysql2::Client.new(config)
    sql = "SELECT * FROM cute_credit.cute_credit_messages where ref_id = '#{self.id}'"
    rec = conn.query(sql).first
    return rec
  end
  def add_payment_methods(params)
    if params[:payment_methods] then
      npms = []
      params[:payment_methods].each do |pm|
        m = PaymentMethod.new(pm)
        m.order_id = self.id
        if m.save then
          self.payment_methods << m
        end
      end
    end
  end
  def remove_payment_method(id)
    pm = self.payment_methods.find_by_id(id)
    if pm then
      pm.destroy
      self.payment_methods.reload
    end
  end
  def loyalty_card
    if self.customer
      return self.customer.loyalty_card
    end
  end
  def rebate_type_display
    REBATE_TYPES.each do |rt|
      return rt[0] if rt[1] == self.rebate_type
    end
    return self.rebate_type
  end

  
  def total=(p)
    return if self.paid == 1
    p = self.string_to_float(p)
    p = p * -1 if self.buy_order == true and p > 0
    write_attribute(:total,p) 
  end
  def front_end_change=(p)
    if self.paid == 1 then
      return
    end
    write_attribute(:front_end_change,self.string_to_float(p)) 
  end
  def rebate=(p)
    return if self.paid == 1
    write_attribute(:rebate,self.string_to_float(p)) 
  end
  def subtotal=(p)
    return if self.paid == 1
    write_attribute(:subtotal,self.string_to_float(p)) 
  end
  def tax=(p)
    return if self.paid == 1
    write_attribute(:tax,self.string_to_float(p)) 
  end
  def toggle_buy_order=(x)
    return if self.paid == 1
    toggle_buy_order(x)
  end
  def toggle_buy_order(x)
    return if self.paid == 1
    if self.buy_order then
      self.update_attribute(:buy_order, false)
    else
      self.update_attribute(:buy_order,true)
    end
    self.order_items.each do |oi|
      oi.price = oi.discover_price(oi.item)
      oi.calculate_total
    end
  end
  def toggle_lock(type)
    if type == 'total' then
      self.update_attribute(:total_is_locked,!self.total_is_locked)
    elsif type == 'subtotal' then
      self.update_attribute(:subtotal_is_locked,!self.subtotal_is_locked)
    elsif type == 'tax' then
      self.update_attribute(:tax_is_locked,!self.tax_is_locked)
    end
  end
  #
  def toggle_tax_free(x)
    self.update_attribute(:tax_free, !self.tax_free)
  end
  #
  def toggle_is_proforma(x)
    self.update_attribute(:is_proforma, !self.is_proforma)
  end
  #
  def get_user
    return self.user if self.user
    return self.user if self.user  
  end
  # This function is mainly used by the api
  def skus=(list)
    list.each do |s|
      if s.class == Array then
        qty = s[1]
        s = s[0]
      end
      item = Item.get_by_code(s)
      if item then
        if item.class == LoyaltyCard then
          self.customer = item
        else
          oi = self.add_item(item)
          if qty then
            oi.quantity = qty
          end
        end
      end #if item
    end # end list.each
  end


  def add_order_item(params={})
    return if self.paid == 1
    
    
    # try to get existing regular item, except coupons
    item = self.order_items.visible.where(['(no_inc IS NULL or no_inc = 0) AND sku = ? AND behavior != ?', params[:sku], 'coupon']).first
    
    if item and item.behavior == 'gift_card' then
      # a gift card has already been added to the order. cannot proceed.
      return nil
    end
    
    if item and not (item.activated or item.is_buyback)
      # simply increment and return
      item.quantity += 1
      item.save
      self.update_self_and_save
      return item
    end
    
    # at this point, we know that the added order item is not yet in the order. so we add a new one
    
    i = self.get_item_by_code(params[:sku])

    if i.class == Item and i.activated == true and i.behavior == 'gift_card' and i.amount_remaining <= 0 then
      # gift card empty. cannot add the order item
      return nil
    end   
    
    if i.class == Item and i.behavior == 'coupon' and not self.order_items.visible.where(:sku => i.coupon_applies).any?
      flash[:notice] = I18n.t("system.errors.coupon_not_enough_items")
      return nil
    end
    
    if i.class == LoyaltyCard then
      self.customer = i.customer
      self.tag = self.customer.full_name
      self.save
      # this is not to be added as an order item, so we return
      return i
    end
    
    if i.class == Item and i.item_type.behavior == 'gift_card' and i.sku == "G000000000000"
      # note that we work with a new item from now on
      i = create_dynamic_gift_card_item
    end
    
    # finally create the order item
    oi = OrderItem.new
    oi.order = self
    oi.set_attrs_from_item(i)
    oi.no_inc = true if params[:no_inc]
    self.order_items << oi
    self.calculate_totals

    # warning about zero price
    if i.base_price.zero? and not i.is_gs1 and not i.must_change_price and not i.default_buyback
      GlobalErrors.append("system.errors.item_price_is_zero")
      SalorBase.beep(1500, 100, 3, 10)
    end
    
    return oi
	end

  
  
  def create_dynamic_gift_card_item
    zero_tax_profile = self.vendor.tax_profiles.visible.where(:value => 0).first
    raise "NoTaxProfileFound" if zero_tax_profile.nil?
    timecode = Time.now.strftime('%y%m%d%H%M%S')
    i = Item.new
    i.sku = "G#{timecode}"
    i.vendor = self.vendor
    i.order = self
    i.tax_profile = zero_tax_profile
    i.name = "Auto Giftcard #{timecode}"
    i.must_change_price = true
    i.behavior = 'gift_card'
    i.item_type = self.vendor.item_types.visible.find_by_behavior('gift_card')
    i.behavior = 'gift_card'
    if not i.save then
      raise "Failed to Save Auto Giftcard"
    end
    return i
  end
  
  
  
  def get_item_by_code(code)     
    # a sku was entered
    item = self.vendor.items.visible.find_by_sku(code)
    return item if item

    # a GS1 barcode was entered
    m = code.match(/\d{2}(\d{5})(\d{5})/)
    item = self.vendor.items.visible.find_by_sku(m[1]) if m
    return item if item


    # a loyalty card was entered
    lcard = self.vendor.loyalty_cards.visible.find_by_sku(code)
    return lcard if lcard
    
    # if nothing existing has been found, create a new item
    i = Item.new
    i.item_type = self.vendor.item_types.find_by_behavior('normal')
    i.behavior = i.item_type.behavior
    i.tax_profile = self.vendor.tax_profiles.where(:default => true).first
    i.vendor = self.vendor
    i.company = self.company
    
    pm = code.match(/(\d{1,9}[\.\,]\d{1,2})/)
    if pm and pm[1]
      # a price in the format xx,xx was entered
      i.sku = "DMY" + Time.now.strftime("%y%m%d") + rand(999).to_s
      i.base_price = code
    else
      # dummy item
      item.sku = code
      item.base_price = 0
    end
    i.name = i.sku
    i.save
    return i
  end
  
  
  #
	def change_given
	  ttl = 0.0
    collection = PaymentMethod.where({:order_id => self.id}).where("internal_type != 'Change' AND internal_type NOT LIKE '%Refund'")
    #collection = self.payment_methods.where("internal_type != 'Change' AND internal_type NOT LIKE '%Refund'")
    #raise collection.inspect
    seen = []
    collection.each do |pm|
      if seen.include? pm.internal_type then
        next
      end
      seen << pm.internal_type
      ttl += pm.amount.to_f
    end
	  return 0 if ttl == 0.0
	  return ttl - self.total
	end
	#
	#def coupons
	#  @cs ||= order_items.where(:behavior => 'coupon') #trying to speed things up a bit.
	#  if not @cs.any? then
	#    return []
	#  end
	#  return @cs 
	#end
	#
	def remove_order_item(oi)
	  if self.paid == 1 and not @current_user.is_technician? then
	    GlobalErrors.append("system.errors.cannot_edit_completed_order")
	    return
	  end
	  nl = []
	  roi = nil
	  order_items.each do |oo|
	    if oo == oi
	      # so we won't add it, but now we need to do some magic if it is a coupon
        oo.update_attribute :hidden, 1
	      if oi.behavior == 'coupon' then
	        roi = self.order_items.joins(:item).readonly(false).where("items.sku = '#{oi.item.coupon_applies}'")
	        if roi then
	          roi = roi.first
	          roi.update_attribute(:coupon_amount,0) if roi
	          roi.update_attribute(:coupon_applied, false) if roi
	        end
	      end
	    end
	  end
	  @cs = nil
	  @gfs = nil
	  update_self_and_save
	  return roi
	end
	#
	#def gift_cards
	#  @gfs ||= order_items.where(:behavior => 'gift_card')
	#  return [] if not @gfs.any?
	#  return @gfs
	#end
	#
	def coupon_for(sku)
	  cps = []
	  coupons.each do |oi|
	    if oi.item.coupon_applies == sku then
	      cps << oi
	    end
	  end if coupons
	  if not cps.any? then
	    return false
	  else
	    return cps
	  end
	end

  

  def calculate_totals
    return nil if self.paid
    self.total = self.order_items.visible.sum(:total)
    self.tax = self.order_items.visible.sum(:tax)
    self.save
  end


  def calculate_tax
    # Add together tax for all items in order
    if self.tax_free then
      self.tax = 0
      return self.tax
    end
    self.tax = 0 if self.tax.nil?
    return self.tax if self.tax_is_locked
    #res = OrderItem.connection.execute("select sum(tax) as taxtotal from order_items where order_id = #{self.id} and behavior = 'normal' and is_buyback is false")
    taxttl = self.order_items.visible.where("order_id = #{self.id} and behavior = 'normal' and is_buyback is false").sum(:tax)
    taxttl.nil? ? self.tax = 0 : self.tax = taxttl.to_f.round(2)
    taxttl
  end
  #
  def gross
    refunded_ttl = self.order_items.where("order_id = #{self.id} and behavior != 'coupon' and is_buyback is false and activated is false and refunded is TRUE").sum(:total).round(2)
    if $Conf.calculate_tax then
      taxttl = self.order_items.visible.where("order_id = #{self.id} and behavior != 'coupon' and is_buyback is false and activated is false and refunded is FALSE").sum(:tax).round(2)
      if self.tax_free then
        taxttl = 0
      end
      nval = self.subtotal + taxttl - refunded_ttl
      return nval.round(2)
    else
      nval = self.subtotal - refunded_ttl
      return nval.round(2)
    end
  end
  #
  def calculate_rebate
    amnt = 0.0
    if self.subtotal.nil? then 
        self.subtotal = 0 
    end
    self.order_items.visible.each do |oi|
      puts "!! Oi.total is #{oi.total}"
      amnt += (oi.total * (self.rebate/100))
    end
    #amnt = (self.subtotal * (self.rebate/100)) #if self.rebate_type == 'percent'
    #amnt = self.rebate if self.rebate_type == 'fixed'
    return amnt
  end

  

  def complete
    # History
    h = History.new
    h.url = "Order::complete"
    h.params = $Params
    h.model_id = self.id
    h.model_type = 'Order'
    h.action_taken = "CompleteOrder"
    h.changes_made = "Beginning complete order"
    h.save

    
    
    self.paid = 1
    self.created_at = Time.now
    self.drawer = self.user.get_drawer
    
    if self.is_quote then
      self.qnr = self.vendor.get_unique_model_number('quote')
    else
      self.nr = self.vendor.get_unique_model_number('order')
    end
    
    self.save

    log_action "Updating quantities"
    order_items.visible.each do |oi|
      oi.set_sold
      oi.update_quantity_sold
      log_action "quantity sold updated"
      oi.update_cash_made
      log_action "cash_made updated"
    end
    log_action "Updating Category Gift Cards"
    activate_gift_cards

    ottl = self.get_drawer_add
    log_action "ottl = self.get_drawer_add #{ottl}"
    if self.buy_order then
      log_action "It's a buy order..."
      create_drawer_transaction(self.get_drawer_add,{:tag => "CompleteOrder"})
    elsif self.total < 0 then
      log_action "Not a buy order, but total < 0"
      create_drawer_transaction(self.get_drawer_add,{:tag => "CompleteOrder"})
    else
      log_action "Creating :drop for complete order with #{ottl}"
      create_drawer_transaction(ottl,{:tag => "CompleteOrder"})
      if self.change_given > 0 and not self.is_quote
        log_action "Creating change PM"
        pm = PaymentMethod.new
        pm.vendor = self.vendor
        pm.internal_type = 'Change'
        pm.amount = - self.change_given
        pm.order = self
        pm.save
      end
      log_action("OID: #{self.id} USER: #{self.user.username} OTTL: #{ottl} DRW: #{self.user.get_drawer.amount}")
      log_action("End of Complete: " + self.payment_methods.inspect)
    end
    
    self.save

    log_action "Ending complete order. Drawer amount is: #{self.user.get_drawer.amount}"
    self.save
  end
  
  def activate_gift_cards
    log_action "Activating giftcards"
    self.gift_cards.each do |gc|
      if gc.item.activated then
        log_action "GC Already Activated, updating"
        gc.item.amount_remaining -= gc.price
        gc.item.amount_remaining = 0 if gc.item.amount_remaining < 0
        gc.item.save
        log_action "gc_saved"
      else
        log_action "Updating GC to Activated"
        gc.item.update_attribute(:activated,true)
        gc.item.update_attribute(:amount_remaining, gc.item.base_price)
      end
    end
  end
  def get_drawer_add
    if self.is_quote or self.unpaid_invoice then
      log_action "Returning 0 because it's a quote #{self.is_quote} or unpaid invoice #{self.unpaid_invoice}"
      return 0 
    end
    return self.payment_methods.reload.where(:internal_type => 'InCash').sum(:amount) if self.is_proforma == true
    
    ottl = self.total
    self.payment_methods.reload.each do |pm|
      next if pm.internal_type == 'InCash'
      ottl -= pm.amount
    end
    #puts "get_drawer_add returning #{ottl}"
    return ottl
  end
  def get_in_cash_amount
    pm = self.payment_methods.where(:internal_type => 'InCash').first
    return pm.amount if pm
    return 0
  end
  def activate_gift_card(id,amount)
    log_action "## Activating Gift Card"
    amount = string_to_float(amount)
    if id.class == OrderItem then
      oi = id
    else
      oi = self.order_items.visible.find_by_id(id)
    end
    if not oi then
      log_action"## not oi, returning"
      return false 
    end
    if not oi.item.activated then
      log_action "Setting activated..."
      oi.item.update_attribute(:activated,true)
      oi.item.update_attribute(:amount_remaining, oi.item.base_price)
      oi.update_attribute(:activated, true)
    end
    if oi.item.amount_remaining < amount then
      log_action "updating attr to #{oi.item.amount_remaining}"
      oi.update_attribute(:price,oi.item.amount_remaining)
      oi.update_attribute(:activated, true)
    else
      log_action "updating attr"
      oi.update_attribute(:price,amount)
      oi.update_attribute(:activated, true)
    end
    return oi
  end

  def create_drawer_transaction(amount,opts={})
    drawer = self.user.get_drawer
    dt = DrawerTransaction.new(opts)
    dt.vendor = self.vendor
    dt.amount = amount
    dt.drawer = drawer
    dt.drawer_amount = drawer.amount
    dt.order = self
    if dt.amount < 0 then
      dt.payout = true
      dt.drop = false
      dt.amount *= -1
    end
    dt.save
    
    if dt.payout == true then
      drawer.amount -= dt.amount
    elsif dt.drop == true then
      drawer.amount += dt.amount
    end
    drawer.save
    
    log_action "creating drawer transaction complete"
    History.direct("Order::create_drawer_transaction",self,{:amount => amount, :opts => opts, :drawer_transaction_id => dt.id},"","");
  end
    

  def create_refund_payment_method(amount, refund_payment_method)
    pm = PaymentMethod.create(:internal_type => (refund_payment_method + 'Refund'), 
                         :name => (refund_payment_method + 'Refund'), 
                         :amount => - amount, 
                         :order_id => self.id
    ) # end of PaymentMethod.create
    log_action "Created payment method: #{pm.inspect}"
    return pm
  end

  def toggle_refund(x, refund_payment_method)
    log_action "toggle_refund called"
    if not @current_user.get_drawer.amount >= self.total then
      log_action "Not enough in drawer"
      GlobalErrors.append_fatal("system.errors.not_enough_in_drawer",self)
      return
    end
    if self.refunded then
      # this is disabled in the view currently
      #self.update_attribute(:refunded, false)
      #create_drawer_transaction(self.total,:drop)
    else
      if (@current_user.get_drawer.amount - self.total) < 0 then
        log_action "drawer amount - total < 0"
      end

      self.update_attribute(:refunded, true)
      self.update_attribute(:refunded_by, @current_user.id)
      self.update_attribute(:refunded_by_type, @current_user.class.to_s)
      if refund_payment_method == 'InCash'
        opts = {:tag => 'OrderRefund',:is_refund => true,:amount => self.total, :notes => I18n.t("views.notice.order_refund_dt",:id => self.id)}
        create_drawer_transaction(self.total, :payout, opts)
        log_action "InCash refund created"
      else
        create_refund_payment_method(self.total, refund_payment_method)
        log_action "created dt for payment method #{payment_method}"
      end
      self.order_items.visible.each do |oi|
        if not oi.refunded == true then
          oi.toggle_refund(nil, refund_payment_method)
        end
      end  
    end
  end
  def refund_total
    t = 0
    self.order_items.where("refunded = 1").each do |oi|
      oi.total = 0 if oi.total.nil?
      t = t + oi.total
    end
    t -= self.calculate_rebate
    log_action "Returning refund_total of #{t}"
    return t
  end

  def to_json
    self.total = 0 if self.total.nil?
    attrs = {
      :total => self.total.round(2),
      :rebate_type => self.rebate_type_display,
      :rebate => self.rebate.round(2),
      :lc_points => self.lc_points,
      :id => self.id,
      :buy_order => self.buy_order,
      :tag => self.tag.nil? ? I18n.t("system.errors.value_not_set") : self.tag,
      :tax_free => self.tax_free,
      :sale_type_id => self.sale_type_id,
      :destination_country_id => self.destination_country_id,
      :origin_country_id => self.origin_country_id,
      :sale_type  => self.sale_type,
      :origin => self.origin_country,
      :destination => self.destination_country,
      :is_proforma => self.is_proforma,
      :order_items => self.order_items
    }
    if self.customer then
      attrs[:customer] = self.customer.json_attrs
      attrs[:loyalty_card] = self.customer.loyalty_card.json_attrs
    end
    attrs.to_json
  end
  def order_items_as_array
    items = []
    self.order_items.visible.each do |oi|
      items << oi.to_json
    end
    return items
  end
  # I moved this stuff here to clean up the views and
  # to make it easier to fix as there were some errors.
  def payment_method_sums
    sums = Hash.new
    self.payment_methods.each do |pm|
      s = pm.internal_type.to_sym
      next if s.nil?
      sums[s] = 0 if sums[s].nil?
      pm.amount = 0 if pm.amount.nil?
      sums[s] += pm.amount
    end
    log_action "payment_method_sums #{sums.inspect}"
    return sums
  end

  def payment_display
    if self.payment_methods.length > 1 then
      return ["Mix",self.total]
    else
      pm = self.payment_methods.first
      return ['Unk',0] if pm.nil?
      return [pm.internal_type,self.total]
    end
  end
  def get_user
    return self.user if self.user
    return self.user if self.user
    if AppConfig.standalone then
      return User.first
    end
    raise "Cannot return User on this order."
  end
  
  def paylife_blurb
    
  end
  def to_list_of_items_raw(array)
    ret = {}
    i = 0
    [:letter,:name,:price,:quantity,:total,:type].each do |k|
      ret[k] = array[i]
      i += 1
    end
    return ret
  end
  def get_report
    # sum_taxes is the taxable sum of money charged by the system
    sum_taxes = Hash.new
    # we turn sum_taxes into a hash of hashes 
    TaxProfile.scopied.each { |t| sum_taxes[t.id] = {:total => 0, :letter => t.letter, :value => 0} }
    subtotal1 = 0
    discount_subtotal = 0
    rebate_subtotal = 0
    refund_subtotal = 0
    coupon_subtotal = 0
    list_of_items = ''
    list_of_items_raw = []
    list_of_taxes_raw = []
    list_of_order_items = []

    integer_format = "%s %-19.19s %6.2f  %3u   %6.2f\n"
    float_format = "%s %-19.19s %6.2f  %5.3f %6.2f\n"
    percent_format = "%s %-19.19s %6.1f%% %3u   %6.2f\n"
    tax_format = "   %s: %2i%% %7.2f %7.2f %8.2f\n"

    self.order_items.visible.each do |oi|
      list_of_order_items << oi
      item_total = 0 if item_total.nil?
      oi.price = 0 if oi.price.nil?
      oi.quantity = 0 if oi.quantity.nil?
      item_price = 0 if item_price.nil?
      name = oi.item.get_translated_name(I18n.locale)

      # Price calculation for normal items
      if oi.behavior == 'normal'
        item_price = oi.price
        item_price *= -1 if self.buy_order
        item_total = item_price * oi.quantity # total cannot be changed and locked any more
      end # passing

      # Price calculation for gift card items
      if oi.behavior == 'gift_card'
        if oi.activated
          # gift card as payment
          item_price = - oi.total
        else
          # gift card sold
          item_price = oi.total
        end
        item_total = item_price * oi.quantity
      end

      # Price calculation for coupon items
      if oi.behavior == 'coupon'
        # current OrderItem is a coupon
        if oi.item.coupon_type == 1
          # parent item has a % coupon set
          item_price = oi.price
          item_total = (- oi.order_item.price * oi.price / 100.0) * oi.quantity # calculation does not rely on other model code, so this is a test
        elsif oi.item.coupon_type == 2
          # parent item has a fixed price coupon set
          item_price = - oi.price # calculation does not rely on other model code, so this is a test
          # item_price = oi.coupon_amount # second possibility to get item_price
          item_total = item_price * oi.quantity
        elsif oi.item.coupon_type == 3
          # parent item has a b1g1 price coupon set
          item_price = - (oi.order_item.price)
          item_total = Integer(oi.order_item.quantity / 2) * item_price
        end
        coupon_subtotal += item_total
        subtotal1 -= item_total # subtotal1 is without any subtractions, so add it again
      end

      # these will accumulate discounts and rebates further down and are needed for tax and refund total calculation
      new_item_price = item_price
      new_item_total = item_total

      # Price calculation for discounts, a separate line will be added below so no modification of item_total
      if oi.discount_applied and not self.buy_order
        discount_price = - oi.discount_amount / oi.quantity
        discount_total = - oi.discount_amount
        new_item_price += discount_price
        new_item_total += discount_total
        if oi.refunded
          discount_price = 0
          discount_total = 0
        end
        discount_subtotal += discount_total
      end

      # Price calculation for rebates, a separate line will be added below so no modification of item_total
      # MF: Diversion between models and this calculation: buyback items with rebates (which does't make sense and nobody will ever use 
      if oi.rebate and oi.rebate > 0
        rebate_price = - ( oi.price * oi.rebate / 100.0)
        rebate_total = rebate_price * oi.quantity
        new_item_price += rebate_price
        new_item_total += rebate_total
        if oi.refunded
          rebate_price = 0
          rebate_total = 0
        end
        rebate_subtotal += rebate_total
      end

      # Price calculation for refunds
      if oi.refunded or ( oi.order_item and oi.order_item.refunded) then
        if not oi.item_type_id == 3
          # this is somewhat of a hack, which would be fixed if coupons would be refunded together with it's OrderItem
          refund_subtotal -= ( item_total - oi.discount_amount - oi.coupon_amount - oi.rebate_amount )
        end
        if self.rebate > 0
          if self.rebate_type == 'percent'
            refund_subtotal += new_item_total * ( 1 - ( 1 - self.rebate / 100.0 ))
          end
          if self.rebate_type == 'fixed'
            refund_subtotal += self.rebate / self.order_items.visible.count
          end
        end
        if self.lc_discount_amount > 0
          refund_subtotal += self.lc_discount_amount /  self.order_items.visible.count
        end
        item_price = 0
        item_total = 0
        new_item_price = 0
        new_item_total = 0
      end

      subtotal1 += item_total

      # Price calculation for taxes
      if not oi.refunded
        sum_taxes[oi.tax_profile_id][:total] += new_item_total # start with unmodified price
        # we can get away with this because it is highly unlikely that the value attribute on a TP changed mid order.
        sum_taxes[oi.tax_profile_id][:value] = oi.tax_profile_amount 
        if self.rebate > 0
          if self.rebate_type == 'percent'
            # distribute % order rebate euqally on all order items
            sum_taxes[oi.tax_profile_id][:total] -= new_item_total * ( 1 - ( 1 - self.rebate / 100.0 ))
          end
          if self.rebate_type == 'fixed'
            # distribute fixed order rebate euqally on all order items
            sum_taxes[oi.tax_profile_id][:total] -= self.rebate / self.order_items.visible.count
          end
        end
        if self.lc_points?
          lc_points_discount = - self.vendor.salor_configuration.dollar_per_lp * self.lc_points
          sum_taxes[oi.tax_profile_id][:total] += lc_points_discount / self.order_items.visible.count
        end
      end

      # THE FOLLOWING IS THE LINE GENERATION

      # NORMAL ITEMS
      if oi.behavior == 'normal'
        if oi.quantity == Integer(oi.quantity)
          # integer quantity
          list_of_items += integer_format % [oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total, 'integer'])
        else
          # float quantity (e.g. weighed OrderItem)
          list_of_items += float_format % [oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total, 'float'])
        end
      end

      # GIFT CARDS
      if oi.behavior == 'gift_card'
        list_of_items += integer_format % [oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total]
        list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total, 'integer'])
      end

      # COUPONS
      if oi.behavior == 'coupon'
        if oi.item.coupon_type == 1
          # percent coupon
          list_of_items += percent_format % [oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total, 'percent'])
        elsif oi.item.coupon_type == 2
          # fixed amount coupon
          list_of_items += integer_format % [oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total, 'integer'])
        elsif oi.item.coupon_type == 3
          # b1g1 coupon
          list_of_items += integer_format % [oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, name, item_price, oi.quantity, item_total, 'integer'])
        end
      end

      # DISCOUNTS
      if oi.discount_applied and not self.buy_order
        discount_name = I18n.t('printr.order_receipt.discount') + ' ' + oi.discounts.first.name
        if oi.quantity == Integer(oi.quantity)
          # integer quantity
          list_of_items += integer_format % [oi.get_tax_profile_letter, discount_name, discount_price, oi.quantity, discount_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, discount_name, discount_price, oi.quantity, discount_total, 'integer'])
        else
          # float quantity
          list_of_items += float_format % [oi.get_tax_profile_letter, discount_name, discount_price, oi.quantity, discount_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, discount_name, discount_price, oi.quantity, discount_total, 'float'])
        end
      end

      # REBATES
      if oi.rebate and oi.rebate > 0
        if oi.quantity == Integer(oi.quantity)
          # integer quantity
          list_of_items += integer_format % [oi.get_tax_profile_letter, I18n.t('printr.order_receipt.rebate'), rebate_price, oi.quantity, rebate_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, I18n.t('printr.order_receipt.rebate'), rebate_price, oi.quantity, rebate_total, 'integer'])
        else
          # float quantity
          list_of_items += float_format % [oi.get_tax_profile_letter, I18n.t('printr.order_receipt.rebate'), rebate_price, oi.quantity, rebate_total]
          list_of_items_raw << to_list_of_items_raw([oi.get_tax_profile_letter, I18n.t('printr.order_receipt.rebate'), rebate_price, oi.quantity, rebate_total, 'float'])
        end
      end

    end # order_items.each do


    if self.lc_discount_amount > 0
      lc_points_discount = - self.lc_discount_amount * (self.nonrefunded_item_count.to_f / self.order_items.visible.count.to_f )
      lc_points_count = self.lc_points * (self.nonrefunded_item_count.to_f / self.order_items.visible.count.to_f )
      subtotal1 += lc_points_discount
    end

    display_subtotal1 = not(self.rebate.zero? and discount_subtotal.zero? and rebate_subtotal.zero? and coupon_subtotal.zero?)

    subtotal2 = subtotal1
    subtotal2 += discount_subtotal if not discount_subtotal.zero?

    subtotal3 = subtotal2
    subtotal3 += rebate_subtotal if not rebate_subtotal.zero?

    subtotal4 = subtotal3
    subtotal4 += coupon_subtotal if not coupon_subtotal.zero?


    order_rebate = 0
    if self.rebate_type == 'percent' and not self.rebate.zero?
      percent_rebate_amount = - subtotal4 * self.rebate / 100.0
      percent_rebate = self.rebate
      order_rebate = percent_rebate_amount
    elsif self.rebate_type == 'fixed' and not self.rebate.zero?
      fixed_rebate_amount = - self.rebate * (self.nonrefunded_item_count.to_f / self.order_items.visible.count.to_f )
      order_rebate = fixed_rebate_amount
    end
    subsubtotal = subtotal4 + order_rebate
    


    paymentmethods = Hash.new
    self.payment_methods.each do |pm|
      next if pm.amount.zero?
      paymentmethods[pm.name] = pm.amount
    end

    list_of_taxes = ''
    # TaxProfiles are not immutable, counting on them to not be hidden/deleted or changed
    # may lead to some small errors. 
    # additionally, TaxProfiles not being immutable means we cannot use their value
    # attribute because it can change overtime.
    # When it comes to a report it is perhaps better to think in terms of
    # what the system charged them for taxes instead of what it should or should not be. 
    # because we don't allow for the deletion of TaxProfiles anymore, we just hid them
    # we can get away with using all for the time being 
    # TaxProfile.scopied.each do |tax|
    TaxProfile.all.each do |tax|
      next if sum_taxes[tax.id] == nil or sum_taxes[tax.id][:total] == 0
      # I.E. what is the percentage decimal of the tax value
      fact = sum_taxes[tax.id][:value] / 100.00
      if self.tax_free == true
        net =  sum_taxes[tax.id][:total]
        gro =  sum_taxes[tax.id][:total]
      else
        # How much of the sum goes to the store after taxes
        if $Conf and not $Conf.calculate_tax then
          net = sum_taxes[tax.id][:total] / (1.00 + fact)
          gro = sum_taxes[tax.id][:total]
        else
          # I.E. The net total is the item total because the tax is outside that price.
          net = sum_taxes[tax.id][:total]
          gro = sum_taxes[tax.id][:total] * (1 + fact)
        end
      end
      # The amount of taxes paid is the gross minus the net total
      vat = gro - net
      list_of_taxes += tax_format % [tax.letter,sum_taxes[tax.id][:value],net,vat,gro]
      list_of_taxes_raw << {:letter => tax.letter, :value => sum_taxes[tax.id][:value], :net => net, :tax => vat, :gross => gro}
    end

    if self.customer
      customer = Hash.new
      customer[:company_name] = self.customer.company_name
      customer[:first_name] = self.customer.first_name
      customer[:last_name] = self.customer.last_name
      customer[:street1] = self.customer.street1
      customer[:street2] = self.customer.street2
      customer[:postalcode] = self.customer.postalcode
      customer[:tax_number] = self.customer.tax_number
      customer[:city] = self.customer.city
      customer[:country] = self.customer.country
      customer[:current_loyalty_points] = self.loyalty_card.points
    end

    report = Hash.new
    report[:order_items] = list_of_order_items
    report[:discount_subtotal] = discount_subtotal
    report[:rebate_subtotal] = rebate_subtotal
    report[:refund_subtotal] = refund_subtotal
    report[:coupon_subtotal] = coupon_subtotal
    report[:list_of_items] = list_of_items
    report[:list_of_items_raw] = list_of_items_raw
    report[:lc_points_discount] = lc_points_discount
    report[:lc_points] = lc_points_count
    report[:subtotal1] = subtotal1
    report[:subtotal2] = subtotal2
    report[:subtotal3] = subtotal3
    report[:subtotal4] = subtotal4
    report[:percent_rebate_amount] = percent_rebate_amount
    report[:percent_rebate] = percent_rebate
    report[:fixed_rebate_amount] = fixed_rebate_amount
    report[:subsubtotal] = self.gross
    report[:paymentmethods] = paymentmethods
    report[:change_given] = self.change_given
    report[:list_of_taxes] = list_of_taxes
    report[:list_of_taxes_raw] = list_of_taxes_raw
    report[:customer] = customer
    report[:unit] = I18n.t('number.currency.format.friendly_unit')

    return report
  end
  
  # new methods from test
  
  def self.generate
    if @current_user.order_id then
      # #puts "OrderId found"
      o = Order.find(@current_user.order_id)
      if o and (not o.paid and not o.order_items.any?) then
        # We already have an empty order.
        return o
      end
    end
    o = Order.new(:tax => 0.0, :subtotal => 0.0, :total => 0.0)
    if o.save then
      # #puts "Updating :order_id"
    else
      # #puts o.errors.inspect
    end
    @current_user.update_attribute :order_id, o.id
    return o
  end
  def belongs_to_current_user?
    if not self.get_user == @current_user then
      return false
    end
    return true
  end
  def inspectify
    txt = "Order[#{self.id}]"
    [:total,:subtotal,:tax,:gross].each do |f|
       txt += " #{f}=#{self.send(f)}"
    end
    self.order_items.each do |oi|
      txt += "\n\tOrderItem[#{oi.id}]"
      [:quantity,:price,:total,:amount_remaining,:activated].each do |f|
        txt += " #{f}=#{oi.send(f)}"
      end
    end
    return txt
  end
  
  
  def escpos_receipt(report)
    vendor = self.vendor
    
    friendly_unit = report[:unit]

    vendorname =
    "\e@"     +  # Initialize Printer
    "\e!\x38" +  # doube tall, double wide, bold
    vendor.name + "\n"

    locale = I18n.locale
    if locale
      tmp = InvoiceBlurb.where(:lang => locale, :vendor_id => self.vendor_id, :is_header => true)
      if tmp.first then
        receipt_blurb_header = tmp.first.body_receipt
      end
      tmp = InvoiceBlurb.where(:lang => locale, :vendor_id => self.vendor_id).where('is_header IS NOT TRUE')
      if tmp.first then
        receipt_blurb_footer = tmp.first.body_receipt
      end
    end
    receipt_blurb_header ||= vendor.salor_configuration.receipt_blurb
    receipt_blurb_footer ||= vendor.salor_configuration.receipt_blurb_footer
    
    receiptblurb_header = ''
    receiptblurb_header +=
    "\e!\x01" +  # Font B
    "\ea\x01" +  # center
    "\n" + receipt_blurb_header.to_s + "\n"
    
    receiptblurb_footer = ''
    receiptblurb_footer = 
    "\ea\x01" +  # align center
    "\e!\x00" + # font A
    "\n" + receipt_blurb_footer.to_s + "\n"
    
    header = ''
    header +=
    "\ea\x00" +  # align left
    "\e!\x01" +  # Font B
    I18n.t("receipts.invoice_numer_X_at_time", :number => self.nr, :datetime => I18n.l(self.created_at, :format => :iso)) + ' ' + self.current_register.name + "\n"

    header += "\n\n" +
    "\e!\x00" +  # Font A
    "\xc4" * 42 + "\n"

    list_of_items = report[:list_of_items]
    list_of_items += "\xc4" * 42 + "\n"
    
    lc_points_discount = ''
    unless report[:lc_points_discount].zero?
      lc_points_discount += "  %19.19s        %4u %8.2f\n" % [I18n.t('printr.order_receipt.lc_points_substracted'), report[:lc_points], report[:lc_points_discount]]
      lc_points_discount += "\xc4" * 42 + "\n"
    end
    
    discount_subtotal = ''
    unless report[:discount_subtotal].zero?
      discount_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.subtotal1'), report[:unit], report[:subtotal1]]
      discount_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.discount_subtotal'), report[:unit], report[:discount_subtotal]]
      discount_subtotal += "\xc4" * 42 + "\n"
    end
    
    item_rebate_subtotal = ''
    unless report[:rebate_subtotal].zero?
      item_rebate_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.subtotal2'), report[:unit], report[:subtotal2]]
      item_rebate_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.rebate_subtotal'), report[:unit], report[:rebate_subtotal]]
      item_rebate_subtotal += "\xc4" * 42 + "\n"
    end
    
    coupon_subtotal = ''
    unless report[:coupon_subtotal].zero?
      coupon_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.subtotal3'), report[:unit], report[:subtotal3]]
      coupon_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.coupon_subtotal'), report[:unit], report[:coupon_subtotal]]
      coupon_subtotal += "\xc4" * 42 + "\n"
    end
    
    order_rebate_subtotal = ''
    if report[:percent_rebate_amount]
      order_rebate_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.subtotal4'), report[:unit], report[:subtotal4]]
      order_rebate_subtotal += "%25.25s %2i%% %s %8.2f\n" % [I18n.t('printr.order_receipt.rebate_percent'), report[:percent_rebate], report[:unit], report[:percent_rebate_amount]]
      order_rebate_subtotal += "\xc4" * 42 + "\n"
    elsif report[:fixed_rebate_amount]
      order_rebate_subtotal += "%29s %s %8.2f\n" % [I18n.t('printr.order_receipt.subtotal4'), report[:unit], report[:subtotal4]]
      order_rebate_subtotal += "%29.29s %s %8.2f\n" % [I18n.t('printr.order_receipt.rebate_fixed'), report[:unit], report[:fixed_rebate_amount]]
      order_rebate_subtotal += "\xc4" * 42 + "\n"
    end
    
    subsubtotal = ''
    subsubtotal += "%29.29s %s %8.2f\n" % [I18n.t('printr.order_receipt.subsubtotal'), report[:unit], report[:subsubtotal]]
    
    paymentmethods = "\n"
    if report[:refund_subtotal].zero?
      paymentmethods += report[:paymentmethods].to_a.collect do |pm|
        "%29.29s %s %8.2f\n" % [pm[0], report[:unit], pm[1]]
      end.join
    else
      paymentmethods += "%29.29s %s %8.2f\n" % [I18n.t('printr.order_receipt.refunded'), report[:unit], report[:refund_subtotal]]
    end

    tax_format = "\n\n" +
    "\ea\x01" +  # align center
    "\e!\x01" # Font A
    tax_header = "         %5.5s     %4.4s  %6.6s\n" % [I18n.t('printr.order_receipt.net'), I18n.t('printr.order_receipt.tax'),
 I18n.t('printr.order_receipt.gross')]
    list_of_taxes = report[:list_of_taxes]
 
    customer = ''
    if report[:customer]
       customer += "%s\n%s %s\n%s\n%s %s\n%s" % [report[:customer][:company_name], report[:customer][:first_name], report[:customer][:last_name], report[:customer][:street1], report[:customer][:postalcode], report[:customer][:city], report[:customer][:tax_number]]
    end

    duplicate = self.was_printed ? " *** DUPLICATE/COPY/REPRINT *** " : ''

    raw_insertations = {}
    if vendor.receipt_logo_header
      headerlogo = "{::escper}headerlogo{:/}"
      raw_insertations.merge! :headerlogo => vendor.receipt_logo_header
    else
      headerlogo = vendorname
    end
    
    if vendor.receipt_logo_footer
      footerlogo = "{::escper}footerlogo{:/}"
      raw_insertations.merge! :footerlogo => vendor.receipt_logo_footer
    else
      footerlogo = ''
    end

    output_text =
        "\e@" +
        "\ea\x01" +  # align center
        headerlogo +
        receiptblurb_header +
        header +
        list_of_items +
        lc_points_discount +
        discount_subtotal +
        item_rebate_subtotal +
        coupon_subtotal +
        order_rebate_subtotal +
        subsubtotal +
        paymentmethods +
        tax_format +
        tax_header +
        list_of_taxes +
        customer +
        receiptblurb_footer +
        duplicate +
        "\n" +
        footerlogo +
        "\n\n\n\n\n\n" + 
        "\x1D\x56\x00" +
        "\x1D\x61\x01"
    return { :text => output_text, :raw_insertations => raw_insertations }
  end
  
  def print
    vendor_printer = VendorPrinter.new :path => @current_register.thermal_printer
    print_engine = Escper::Printer.new('local', vendor_printer)
    print_engine.open
    
    contents = self.escpos_receipt(self.get_report)
    bytes_written, content_written = print_engine.print(0, contents[:text], contents[:raw_insertations])
    print_engine.close
    Receipt.create(:user_id => self.user_id, :current_register_id => self.current_register_id, :content => contents[:text], :order_id => self.id)
  end
  def sanity_check
    if self.paid == 1 then
      pms = self.payment_methods.collect { |pm| pm.internal_type}
      if pms.include? "InCash" and not pms.include? "Change" and self.change_given > 0 then
        puts "Order is missing Change Payment Method"
        PaymentMethod.create(:vendor_id => self.vendor_id, :internal_type => 'Change', :amount => - self.change_given, :order_id => self.id)
        self.payment_methods.reload
      end
      pms_seen = []
      self.payment_methods.each do |pm|
        if pms_seen.include? pm.internal_type then
          puts "Deleting pm..."
          pm.delete
        else
          pms_seen << pm.internal_type
        end
      end
      self.payment_methods.reload
    end
  end
  
  def check
    messages = []
    tests = []
    
    if self.paid
      tests[1] = self.payment_methods.sum(:amount).round(2) == self.total.round(2)
    end
    
    0.upto(tests.size-1).each do |i|
      messages << "Order #{ self.id }: test#{i} failed." if tests[i] == false
    end
    return messages
  end
  
  def self.check_range(from, to)
    orders = Order.where(:paid => 1, :created_at => from..to)
    
    messages = []
    tests = []
    
    orders.each do |o|
      if o.paid
        tests[1] = o.payment_methods.sum(:amount).round(2) == o.total.round(2)
      end
    
      0.upto(tests.size-1).each do |i|
        if tests[i] == false
          messages << "Order #{ o.id }: test#{i} failed." 
        else
          messages << []
        end
      end
    end
    return messages
  end
  # {END}
end

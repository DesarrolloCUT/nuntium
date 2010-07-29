require 'digest/sha2'

class Application < ActiveRecord::Base
  belongs_to :account
  has_many :ao_messages
  has_many :at_messages
  has_many :address_sources
  has_many :cron_tasks, :as => :parent, :dependent => :destroy
  
  attr_accessor :password_confirmation
  
  validates_presence_of :account_id
  validates_presence_of :name, :password, :interface
  validates_confirmation_of :password
  validates_uniqueness_of :name, :scope => :account_id, :message => 'has already been used by another application in the account'
  validates_inclusion_of :interface, :in => ['rss', 'qst_client', 'http_post_callback']
  validates_presence_of :interface_url, :unless => Proc.new {|app| app.interface == 'rss'}
  validates_presence_of :delivery_ack_url, :unless => Proc.new {|app| app.delivery_ack_method == 'none'}
  
  serialize :configuration, Hash
  serialize :ao_rules
  
  before_save :hash_password
  
  after_save :handle_tasks
  after_create :create_worker_queue
  after_save :bind_queue
  
  before_destroy :clear_cache 
  after_save :clear_cache
  
  include(CronTask::CronTaskOwner)
  
  # Route an AOMessage
  def route_ao(msg, via_interface)
    return if duplicated? msg
    
    # Fill some fields
    fill_common_message_properties msg
    
    # Check protocol presence
    protocol = msg.to.nil? ? '' : msg.to.protocol
    
    if protocol == ''
      msg.state = 'failed'
      msg.save!
      logger.ao_message_received msg, via_interface
      logger.protocol_not_found_for_ao_message msg
      return true
    end
    
    # Save mobile number information
    mob = MobileNumber.update msg.to.mobile_number, msg.country, msg.carrier if protocol == 'sms'
    
    # Get the list of candidate channels
    channels = candidate_channels_for_ao msg, :mobile_number => mob
    
    # Exit if no candidate channel 
    if channels.empty?
      msg.state = 'failed'
      msg.save!
      
      logger.ao_message_received msg, via_interface
      logger.no_channel_found_for_ao_message protocol, msg
      return true
    end
    
    # Route to the only channel if that's the case
    if channels.length == 1
      channels.first.route_ao msg, via_interface
      return true
    end
    
    # Or route according to a strategy
    final_strategy = msg.strategy || strategy
    if final_strategy == 'broadcast'
      msg.state = 'broadcasted'
      msg.save!
      
      logger.ao_message_received msg, via_interface
      logger.ao_message_broadcasted msg
      
      channels.each do |channel|
        copy = msg.clone
        copy.state = 'pending'
        copy.guid = Guid.new.to_s
        copy.parent_id = msg.id
        
        channel.route_ao copy, via_interface
      end
    else
      # Select channels with less or equal priority than the other channels
      channels = channels.select{|c| channels.all?{|x| (c.priority || 100) <= (x.priority || 100) }}
      
      # Select a random channel to handle the message
      channels.rand.route_ao msg, via_interface
    end
    true
  rescue => e
    # Log any errors and return false
    logger.error_routing_msg msg, e
    return false
  end
  
  def reroute_ao(msg)
    msg.tries = 0
    msg.state = 'pending'
    self.route_ao msg, 're-route'
  end
  
  def route_at(msg, via_channel)
    msg.application_id = self.id
  
    # Update AddressSource if desired and if it the channel is bidirectional
    if use_address_source? and via_channel.kind_of? Channel and via_channel.direction == Channel::Bidirectional
      as = AddressSource.find_by_application_id_and_address_and_channel_id self.id, msg.from, via_channel.id
      if as.nil?
        AddressSource.create!(:account_id => account.id, :application_id => self.id, :address => msg.from, :channel_id => via_channel.id) 
      else
        as.touch
      end
    end
    
    # save the message here so we have and id for the later job
    msg.save!
    
    # Check if callback interface is configured
    if self.interface == 'http_post_callback'
      Queues.publish_application self, SendPostCallbackMessageJob.new(msg.account_id, msg.application_id, msg.id)
    end
        
    if 'ui' == via_channel
      logger.at_message_created_via_ui msg
    else
      logger.at_message_received_via_channel msg, via_channel if !via_channel.nil?
    end
  end
  
  # Returns the candidate channels when routing an ao message.
  # Optimizations can be:
  #  - :mobile_number => associated to the message, so that it does not need to
  #                      be read when completing missing fields
  def candidate_channels_for_ao(msg, optimizations = {})
    # Fill some fields
    fill_common_message_properties msg
    
    # Find protocol of message (based on "to" field)
    protocol = msg.to.nil? ? '' : msg.to.protocol
    return [] if protocol == ''
    
    # Infer attributes
    msg.infer_custom_attributes optimizations
    
    # AO Rules
    ao_rules_res = RulesEngine.apply(msg.rules_context, self.ao_rules)
    msg.merge ao_rules_res
    
    # Get all outgoing enabled channels
    channels = account.channels.select{|c| c.enabled && c.is_outgoing?}
    
    # Find channels that handle that protocol
    channels = channels.select {|x| x.protocol == protocol}
    
    # Filter them according to custom attributes
    channels = channels.select{|x| x.can_route_ao? msg}
    
    # See if the message includes a suggested channel
    if msg.suggested_channel
      suggested_channel = channels.select{|x| x.name == msg.suggested_channel}.first
      return [suggested_channel] if suggested_channel
    end
    
    # See if there is a last channel used to route an AT message with this address
    last_channel = get_last_channel msg.to, channels
    return [last_channel] if last_channel
    
    channels.sort!{|x, y| (x.priority || 100) <=> (y.priority || 100)}
    
    return channels
  end
  
  def self.find_all_by_account_id(account_id)
    apps = Rails.cache.read cache_key(account_id)
    if not apps
      apps = Application.all :conditions => ['account_id = ?', account_id]
      Rails.cache.write cache_key(account_id), apps
    end
    apps
  end
  
  def configuration
    self[:configuration] = {} if self[:configuration].nil?
    self[:configuration]
  end
  
  def is_rss
    self.interface == 'rss'
  end
  
  def authenticate(password)
    self.password == Digest::SHA2.hexdigest(self.salt + password)
  end
  
  def self.configuration_accessor(name, default = nil)
    define_method(name) do
      configuration[name] || default
    end
    define_method("#{name}=") do |value|
      configuration[name] = value
    end
  end
  
  configuration_accessor :interface_url
  configuration_accessor :interface_user
  configuration_accessor :interface_password
  configuration_accessor :strategy, 'single_priority'
  configuration_accessor :delivery_ack_method, 'none'
  configuration_accessor :delivery_ack_url
  configuration_accessor :delivery_ack_user
  configuration_accessor :delivery_ack_password
  configuration_accessor :last_at_guid
  configuration_accessor :last_ao_guid
  
  def use_address_source?
    configuration[:use_address_source] || true
  end
  
  def use_address_source=(value)
    if value
      configuration[:use_address_source] = true
    else
      configuration.delete :use_address_source
    end
  end
  
  def strategy_description
    Application.strategy_description(strategy)
  end
  
  def self.strategy_description(strategy)
    case strategy
    when 'broadcast'
      'Broadcast'
    when 'single_priority'
      'Single (priority)'
    end
  end
  
  def delivery_ack_method_description
    case delivery_ack_method
    when 'none'
      'None'
    when 'get'
      "HTTP GET #{delivery_ack_url}"
    when 'post'
      "HTTP POST #{delivery_ack_url}"
    end
  end
  
  def self.delivery_ack_method_description(method)
    case method
    when 'none'
      'None'
    when 'get'
      "HTTP GET"
    when 'post'
      "HTTP POST"
    end
  end
  
  def interface_description
    case interface
    when 'rss'
      return 'Rss'
    when 'qst_client'
      return "QST client: #{interface_url}"
    when 'http_post_callback'
      return "HTTP POST callback: #{interface_url}"
    end
  end
  
  def alert(alert_msg)
    account.alert alert_msg
  end
  
  def logger
    account.logger
  end
  
  protected
  
  # Ensures tasks for this account are correct
  def handle_tasks(force = false)
    if self.interface_changed? || force
      case self.interface
        when 'qst_client'
          create_task('qst-push', QST_PUSH_INTERVAL, PushQstMessageJob.new(self.id))
          create_task('qst-pull', QST_PULL_INTERVAL, PullQstMessageJob.new(self.id))
      else
        drop_task('qst-push')
        drop_task('qst-pull')
      end
    end
  end
  
  def create_worker_queue
    WorkerQueue.create!(:queue_name => Queues.application_queue_name_for(self), :working_group => 'fast', :ack => true)
  end
  
  def bind_queue
    Queues.bind_application self
    true
  end
  
  private
  
  def duplicated?(msg)
    return false if !msg.new_record? || msg.guid.nil?
    msg.class.exists?(['application_id = ? and guid = ?', self.id, msg.guid])
  end
  
  def fill_common_message_properties(msg)
    if msg.new_record?
      msg.account ||= self.account
      msg.application ||= self
      msg.timestamp ||= Time.now.utc
    end
  end
  
  def get_last_channel(address, outgoing_channels)
    return nil unless use_address_source?
    ass = AddressSource.all :conditions => ['application_id = ? AND address = ?', self.id, address], :order => 'updated_at DESC'
    return nil if ass.empty?
    
    # Return the first outgoing_channel that was used as a last channel.
    ass.each do |as|
      candidate = outgoing_channels.select{|x| x.id == as.channel_id}.first
      return candidate if candidate
    end
    return nil
  end
  
  def hash_password
    return if self.salt.present?
    
    self.salt = ActiveSupport::SecureRandom.base64(8)
    self.password = Digest::SHA2.hexdigest(self.salt + self.password) if self.password
    self.password_confirmation = Digest::SHA2.hexdigest(self.salt + self.password_confirmation) if self.password_confirmation
  end
  
  def clear_cache
    Rails.cache.delete Application.cache_key(account_id)
    true
  end
  
  def self.cache_key(account_id)
    "account_#{account_id}_applications"
  end
end

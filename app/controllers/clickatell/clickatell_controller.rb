require 'iconv'

class ClickatellController < ApplicationController
  before_filter :authenticate

  @@clickatell_timezone = ActiveSupport::TimeZone.new 2.hours

  # GET /clickatell/:application_id/incoming
  def index
    udh = ClickatellUdh.from_string params[:udh]
    if udh
      index_multipart_message udh
    else
      index_single_message
    end
  end
  
  def index_single_message
    create_message params[:text]
    head :ok
  end
  
  def index_multipart_message(udh)
    # Search other received parts
    conditions = ['originating_isdn = ? AND reference_number = ?', params[:from], udh.reference_number]
    parts = ClickatellMessagePart.all(:conditions => conditions)
    
    # If all other parts are there
    if parts.length == udh.part_count - 1
      # Add this new part, sort and get text
      parts.push ClickatellMessagePart.new(:part_number => udh.part_number, :text => params[:text])
      parts.sort! { |x,y| x.part_number <=> y.part_number }
      text = parts.collect { |x| x.text }.to_s
      
      # Create message from the resulting text
      create_message text
      
      # Delete stored information
      ClickatellMessagePart.delete_all conditions
    else
      # Just save the part
      ClickatellMessagePart.create(
        :originating_isdn => params[:from],
        :reference_number => udh.reference_number,
        :part_count => udh.part_count,
        :part_number => udh.part_number,
        :timestamp => get_timestamp,
        :text => params[:text]
        )
    end
    
    head :ok
  end
  
  def create_message(text)
    msg = ATMessage.new
    msg.from = 'sms://' + params[:from]
    msg.to = 'sms://' + params[:to]
    msg.subject = Iconv.new('UTF-8', params[:charset]).iconv(text)
    msg.channel_relative_id = params[:moMsgId]
    msg.timestamp = get_timestamp
    @application.accept msg, @channel
  end
  
  def get_timestamp
    @@clickatell_timezone.parse(params[:timestamp]).utc rescue Time.now.utc
  end
  
  def authenticate
    authenticate_or_request_with_http_basic do |username, password|
      @application = Application.find_by_id_or_name(params[:application_id])
      if !@application.nil?
        channels = @application.channels.find_all_by_kind 'clickatell'
        channels = channels.select { |c| 
          c.name == username && 
          c.configuration[:incoming_password] == password &&
          c.configuration[:api_id] == params[:api_id] }
        if channels.empty?
          false
        else
          @channel = channels[0]
          true
        end
      else
        false
      end
    end
  end
end
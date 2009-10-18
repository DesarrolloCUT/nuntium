class OutgoingController < ApplicationController
  # GET /qst/outgoing
  def index
    etag = request.env['HTTP_IF_NONE_MATCH']
    max = params[:max]
    
    # Read unread messages
    unread_messages = UnreadOutMessage.all(:order => :id)

    # Remove entries previous to etag    
    if !etag.nil?
      count = 0
      unread_messages.each do |msg|
        count += 1
        if msg.guid == etag
          UnreadOutMessage.delete_all("id <= #{msg.id}")
          break
        end
      end
      
      # Keep the ones after the etag
      unread_messages = unread_messages[count ... unread_messages.length]
    end
    
    # Keep only max of them
    if !max.nil?
      unread_messages = unread_messages[0 ... max.to_i]
    end
    
    # Keep only ids of messages
    unread_messages.collect! {|x| x.guid }
    
    @out_messages = OutMessage.all(:order => 'timestamp', :conditions => ['guid IN (?)', unread_messages])
    
    if !@out_messages.empty?
      response.headers['ETag'] = @out_messages.last.guid
    end
  end
end
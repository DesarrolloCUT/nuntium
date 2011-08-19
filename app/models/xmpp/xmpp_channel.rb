require 'xmpp4r/client'

class XmppChannel < Channel
  include ServiceChannel
  include Jabber

  configuration_accessor :user, :password, :domain, :port, :resource, :server

  validates_presence_of :user, :domain, :password
  validates_numericality_of :port, :greater_than => 0

  def self.title
    "XMPP"
  end

  def jid
    jid = "#{user}@#{domain}"
    jid << "/#{resource}" if resource.present?
    jid
  end

  def server
    configuration[:server].presence
  end

  def check_valid_in_ui
    begin
      client = Client::new JID::new(jid)
      client.connect server, port
      client.auth password
    rescue => e
      errors.add_to_base e.message
    ensure
      client.close
    end
  end

  def info
    port_part = port.to_i == 5222 ? '' : ":#{port}"
    "#{user}@#{domain}#{port_part}/#{resource}"
  end
end
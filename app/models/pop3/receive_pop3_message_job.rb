# Copyright (C) 2009-2012, InSTEDD
# 
# This file is part of Nuntium.
# 
# Nuntium is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# Nuntium is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with Nuntium.  If not, see <http://www.gnu.org/licenses/>.

require 'net/pop'
require 'mail'

class ReceivePop3MessageJob

  attr_accessor :account_id, :channel_id

  include CronTask::QuotedTask

  def initialize(account_id, channel_id)
    @account_id = account_id
    @channel_id = channel_id
  end

  def perform
    account = Account.find @account_id
    @channel = account.channels.find_by_id @channel_id
    config = @channel.configuration
    remove_quoted = config[:remove_quoted_text_or_text_after_first_empty_line].to_b

    pop = Net::POP3.new(config[:host], config[:port].to_i)
    pop.enable_ssl(OpenSSL::SSL::VERIFY_NONE) if config[:use_ssl].to_b

    begin
      pop.start(config[:user], config[:password])
    rescue Net::POPAuthenticationError => ex
      @channel.alert "#{ex}"

      @channel.enabled = false
      @channel.save!
      return
    end

    pop.each_mail do |mail|
      tmail = Mail.read_from_string mail.pop
      tmail_body = get_body tmail

      sender = (tmail.from || []).first
      receiver = (tmail.to || []).first

      msg = AtMessage.new
      msg.from = "mailto://#{sender}"
      msg.to = "mailto://#{receiver}"
      msg.subject = tmail.subject
      msg.body = tmail_body
      if remove_quoted
        msg.body = ReceivePop3MessageJob.remove_quoted_text_or_text_after_first_empty_line msg.body
      end
      msg.channel_relative_id = tmail.message_id
      msg.timestamp = tmail.date

      # Process references to set the thread and reply_to
      if tmail.references.present?
        tmail.references.split(',').map(&:strip).each do |ref|
          at_index = ref.index('@')
          next unless ref.start_with?('<') || !at_index
          if ref.end_with?('@message_id.nuntium>')
            msg.custom_attributes['reply_to'] = ref[1 .. -21]
          elsif ref.end_with?('.nuntium>')
            msg.custom_attributes["references_#{ref[at_index + 1 .. -10]}"] = ref[1 ... at_index]
          end
        end
      end

      account.route_at msg, @channel

      mail.delete
      break if not has_quota?
    end

    pop.finish
  rescue => ex
    puts ex
    puts ex.backtrace
    AccountLogger.exception_in_channel @channel, ex if @channel
  end

  def self.remove_quoted_text_or_text_after_first_empty_line(text)
    result = ""
    text.strip.lines.each do |line|
      line = line.strip
      break if line.empty?
      break if line.start_with? '>'
      break if line.start_with?('On') && line.end_with?(':')
      result << line
      result << "\n"
    end
    result.strip
  end

  private

  def get_body(tmail)
    tmail = tmail.body

    # Not multipart? Return body as is.
    return tmail.to_s if !tmail.multipart?

    # Return text/plain part.
    tmail.parts.each do |part|
      return part.body.decoded if part.content_type =~ %r(text/plain)
    end

    # Or body if not found
    return tmail.to_s
  end
end

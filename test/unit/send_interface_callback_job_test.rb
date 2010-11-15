require 'test_helper'

class SendInterfaceCallbackJobTest < ActiveSupport::TestCase
  def setup
    @application = Application.make
    @chan = Channel.make :account => @application.account, :application => @application
    @msg = ATMessage.make :account => @application.account, :application => @application, :channel => @chan
    @query = {
      :application => @application.name,
      :from => @msg.from,
      :to => @msg.to,
      :subject => @msg.subject,
      :body => @msg.body,
      :guid => @msg.guid,
      :channel => @chan.name
    }
  end

  test "get" do
    @application.interface = 'http_get_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.save!

    expect_get :url => @application.interface_url,
      :query_params => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}},
      :returns => Net::HTTPSuccess

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform
  end

  test "get with auth" do
    @application.interface = 'http_get_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.interface_user = 'john'
    @application.interface_password = 'pass'
    @application.save!

    expect_get :url => @application.interface_url,
      :query_params => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}, :user => @application.interface_user, :password => @application.interface_password},
      :returns => Net::HTTPSuccess

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform
  end

  test "post" do
    @application.interface = 'http_post_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.save!

    expect_post :url => @application.interface_url,
      :data => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}},
      :returns => Net::HTTPSuccess

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform
  end

  test "post with auth" do
    @application.interface = 'http_post_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.interface_user = 'john'
    @application.interface_password = 'pass'
    @application.save!

    expect_post :url => @application.interface_url,
      :data => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}, :user => @application.interface_user, :password => @application.interface_password},
      :returns => Net::HTTPSuccess

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform
  end

  test "post unauthorized" do
    @application.interface = 'http_post_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.save!

    expect_post :url => @application.interface_url,
      :data => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}},
      :returns => Net::HTTPUnauthorized

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform

    @application.reload
    assert_equal 'rss', @application.interface
  end

  test "discard not queued messages" do
    expect_no_rest

    @msg.state = 'cancelled'
    @msg.save!

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    assert_true job.perform
  end

  test "post response is a text, route it back" do
    @application.interface = 'http_post_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.save!

    expect_post :url => @application.interface_url,
      :data => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}},
      :returns => Net::HTTPSuccess,
      :returns_body => 'foo'

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform

    msgs = AOMessage.all
    assert_equal 1, msgs.count
    assert_equal @application.account_id, msgs[0].account_id
    assert_equal @application.id, msgs[0].application_id
    assert_equal @chan.id, msgs[0].channel_id
    assert_equal @msg.to, msgs[0].from
    assert_equal @msg.from, msgs[0].to
    assert_equal 'foo', msgs[0].body
  end

  test "post with custom attributes" do
    @application.interface = 'http_post_callback'
    @application.interface_url = 'http://www.domain.com'
    @application.save!

    @msg.country = 'ar'
    @msg.carrier = 'some_guid'
    @msg.save!

    @query['country'] = 'ar'
    @query['carrier'] = 'some_guid'

    expect_post :url => @application.interface_url,
      :data => @query,
      :options => {:headers => {:content_type => "application/x-www-form-urlencoded"}},
      :returns => Net::HTTPSuccess

    job = SendInterfaceCallbackJob.new @application.account_id, @application.id, @msg.id
    job.perform
  end
end
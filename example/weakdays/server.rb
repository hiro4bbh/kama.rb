#!/usr/bin/env ruby
require 'fileutils'
require 'sqlite3'
require 'webrick'

$:.unshift(File.join(File.dirname(__FILE__), '..', '..', 'lib'))
require 'kama.rb'

def datetime_to_s(date)
  date.iso8601[0..-10]
end
def parse_datetime(str)
  begin
    return DateTime.parse(str)
  rescue
    return DateTime.now
  end
end
def time_to_s(date)
  date.to_s[11..-10]
end
def timestamp_to_datetime(ts)
  Time.at(Time.at(ts).getutc).to_datetime
end
def wday_to_s(wday)
  ['Sun', 'Mon', 'Tue', 'Wed', 'Thr', 'Fri', 'Sat'][wday]
end

class Database < SQLite3::Database
  @@palette = ['black', 'blue', 'green', 'orange', 'purple', 'red']
  def self.palette
    @@palette
  end

  attr_reader :path
  def initialize(path)
    @path = path
    FileUtils::mkdir_p(File.dirname(path))
    super(path)
  end

  def create_table(tblname, schema: {})
    execute("CREATE TABLE #{tblname} ( #{schema.map do |k, v| "#{k} #{v}" end.join(',')} );")  # Raw Input Value
  end
  def table_exists?(tblname)
    execute("SELECT name FROM sqlite_master WHERE type = 'table' and name='#{tblname}'").length > 0  # Raw Input Value
  end

  def create_table_calendars
    create_table('calendars', schema: {
      'cid':      'INTEGER PRIMARY KEY',
      'calname':  'TEXT',
      'uid':      'INTEGER',
      'color':    'TEXT',
    })
  end
  def create_table_events
    create_table('events', schema: {
      'eid':       'INTEGER PRIMARY KEY',
      'cid':       'INTEGER',
      'uid':       'INTEGER',
      'start_at':  'INTEGER',
      'finish_at': 'INTEGER',
      'title':     'TEXT',
      'content':   'TEXT',
    })
  end
  def create_table_users
    create_table('users', schema: {
      'uid':      'INTEGER PRIMARY KEY',
      'username': 'TEXT',
      'password': 'TEXT',
    })
  end
  def create_calendar(calname, uid, color: 'blue')
    execute("INSERT INTO calendars(calname, uid, color) VALUES ('#{calname}', #{uid}, '#{color}');")  # Raw Input Value
  end
  def create_event(cid, uid, start_at, finish_at, title, content)
    start_at, finish_at = start_at.to_time.to_i, finish_at.to_time.to_i
    raise "Finish time should be later than start time" unless start_at < finish_at
    execute("INSERT INTO events(cid, uid, start_at, finish_at, title, content) VALUES (#{cid}, #{uid}, #{start_at}, #{finish_at}, '#{title}', '#{content}');")  # Raw Input Value
  end
  def create_user(username, password)
    execute("INSERT INTO users(username, password) VALUES ('#{username}', '#{password}');")  # Raw Input Value
  end
  def signup_user(username, password)
    create_user(username, password)
    user = select_user(username)
    create_calendar('default', user[:uid])
    create_calendar('home', user[:uid], color: 'orange')
    return user
  end

  def delete_calendar(cid)
    # Why not using atomic operations?
    execute("DELETE FROM calendars WHERE cid = #{cid};")  # Raw Input Value
    execute("DELETE FROM events WHERE cid = #{cid};")  # Raw Input Value
  end
  def delete_event(eid)
    execute("DELETE FROM events WHERE eid = #{eid};")  # Raw Input Value
  end

  def edit_calendar(cid, calname, color)
    execute("UPDATE calendars SET calname = '#{calname}', color = '#{color}' WHERE cid = #{cid};")  # Raw Input Value
  end
  def edit_event(eid, cid, start_at, finish_at, title, content)
    start_at, finish_at = start_at.to_time.to_i, finish_at.to_time.to_i
    raise "Finish time should be later than start time" unless start_at < finish_at
    execute("UPDATE events SET cid = #{cid}, start_at = #{start_at}, finish_at = #{finish_at}, title = '#{title}', content = '#{content}' WHERE eid = #{eid};")  # Raw Input Value
  end

  def select_calendar(cid)
    res = execute("SELECT * FROM calendars WHERE cid = #{cid} LIMIT 0, 1;")  # Raw Input Value
    return nil if res.length == 0
    return [:cid, :calname, :uid, :color].zip(res[0]).to_h
  end
  def select_calendars(uid)
    res = execute("SELECT * FROM calendars WHERE uid = #{uid};")  # Raw Input Value
    return res&.map do |row| [:cid, :calname, :uid, :color].zip(row).to_h end
  end
  def select_event(eid)
    res = execute("SELECT * FROM events INNER JOIN calendars ON events.cid = calendars.cid WHERE eid = #{eid} LIMIT 0, 1;")  # Raw Input Value
    return nil if res.length == 0
    return [:eid, :cid, :uid, :start_at, :finish_at, :title, :content, :cid, :calname, :uid, :color].zip(res[0]).to_h
  end
  def select_events(uid, start_at, finish_at)
    start_at, finish_at = start_at.to_time.to_i, finish_at.to_time.to_i
    res = execute("SELECT * FROM events INNER JOIN calendars ON events.cid == calendars.cid WHERE events.uid = #{uid} AND ((#{start_at} <= start_at AND start_at < #{finish_at}) OR (start_at <= #{start_at} AND #{start_at} < finish_at));")  # Raw Input Value
    return res&.map do |row| [:eid, :cid, :uid, :start_at, :finish_at, :title, :content, :cid, :calname, :uid, :color].zip(row).to_h end
  end
  def select_user(username)
    res = execute("SELECT * FROM users WHERE username = '#{username}' LIMIT 0, 1;")  # Raw Input Value
    return nil if res.length == 0
    return [:uid, :username, :password].zip(res[0]).to_h
  end
end

class Server
  attr_reader :db, :addr, :port
  def initialize(db, respath, addr, port)
    @db, @addr, @port = db, addr, port
    @server = WEBrick::HTTPServer.new({:BindAddress=>addr, :Port=>port, :Logger=>Kama.logger})
    @server.mount('/res', WEBrick::HTTPServlet::FileHandler, respath)
    @server.mount_proc('/calendar', method(:handler_calendar))
    @server.mount_proc('/event', method(:handler_event))
    @server.mount_proc('/session', method(:handler_session))
    @server.mount_proc('/', method(:handler_index))
    trap('INT') do
      @server.shutdown
    end
    @rng = Random.new
    @sessions = {}
  end

  def start
    @server.start
  end

  def create_session(res, user)
    sessid = @rng.rand(1<<64).to_s(26).tr('0-9a-q', 'A-Z').rjust(14, 'A')
    session = @sessions[sessid] = {:sessid=>sessid, :user=>user}
    res.cookies << CGI::Cookie.new('SESSID', sessid)
    return session
  end
  def discard_session(res, session)
    res.cookies << CGI::Cookie.new('SESSID', '')
    @sessions.delete session[:sessid]
  end
  def get_session(req)
    sessid = req.cookies.find do |key| key.name == 'SESSID' end&.value
    return @sessions[sessid]
  end

  def get_result(uid, target_date)
    start_date = target_date.to_date.to_datetime.prev_day(target_date.wday)
    last_date = start_date.next_day(7)
    days, date = [], start_date
    while date < last_date
      days << {:date=>date, :events=>@db.select_events(uid, date, date.next_day)}
      date = date.next_day
    end
    return {:prevweek_date=>start_date.prev_day(7), :nextweek_date=>last_date, :days=>days}
  end

  def generate_302_found(res, path)
    res['location'] = path  # Raw Input Value
    raise WEBrick::HTTPStatus::Found
  end
  def generate_404_not_found(res)
    raise WEBrick::HTTPStatus::NotFound
  end
  def generate_html_header(res, title: '')
    res['x-xss-protection'] = '0'
    res.body << '<html>'
    res.body << '<head>'
    res.body << '<link rel="stylesheet" type="text/css" href="/res/style.css" />'
    res.body << "<title>#{title}#{if title.empty? then '' else ' - ' end}Weakdays</title>"  # Raw Input Value
    res.body << '</head>'
    res.body << '<body>'
  end
  def generate_usermsg(username)
    greet = case DateTime.now.hour
      when 6..8
        'Good morning'
      when 9..18
        'Good afternoon'
      else
        'Good evening'
      end
    "#{greet}, #{username}!!"  # Raw Input Value
  end
  def generate_body_header(res, title: '', usermsg: nil)
    res.body << "<h1>#{title} - Weakdays</h1>"  # Raw Input Value
    if usermsg then
      res.body << '<header>'
      res.body << usermsg  # Raw Input Value
      res.body << '&nbsp; <a class="nav" href="/">Top</a>'
      res.body << '&nbsp; <a class="nav" href="/calendar?action=list">Manage</a>'
      res.body << '&nbsp; <a class="nav" href="/session?action=signout">Sign Out</a>'
      res.body << '</header>'
    end
  end
  def generate_html_footer(res)
    res.body << '<footer>'
    res.body << "generated at: #{DateTime.now()}<br>"
    res.body << 'Copyright &copy; 2018- Tatsuhiro Aoshima (hiro4bbh@gmail.com).'
    res.body << '</footer>'
    res.body << '</body>'
    res.body << '</html>'
    raise WEBrick::HTTPStatus::OK
  end
  def generate_error_dialog(res, message)
    res.body << "<div class=\"error\">ERROR: #{message}</div>" if message  # Raw Input Value
  end
  def generate_form(res, action, method: 'GET')
    res.body << "<form action=\"#{action}\" method=\"#{method}\"><table><tbody>"  # Raw Input Value
    yield
    res.body << '</tbody></table></form>'
  end
  def generate_form_hidden(res, name, value)
    res.body << "<input type=\"hidden\" name=\"#{name}\" value=\"#{value}\">"  # Raw Input Value
  end
  def generate_form_input(res, label, name, value: '',  type: 'text', style: '')
    res.body << "<tr><th><label>#{label}</label></th><td><input type=\"#{type}\" name=\"#{name}\" value=\"#{value}\" style=\"#{style}\"></td></tr>"  # Raw Input Value
  end
  def generate_form_select(res, label, name)
    res.body << "<tr><th><label>#{label}</label></th><td><select name=\"#{name}\">"  # Raw Input Value
    yield
    res.body << '</select></td></tr>'
  end
  def generate_form_select_option(res, label, value, clazz: nil, selected: false)
    res.body << "<option #{if clazz then "class=\"#{clazz}\"" else '' end} value=\"#{value}\" #{if selected then 'selected' else '' end}>#{label}</option>"  # Raw Input Value
  end
  def generate_form_submit(res, value)
    res.body << "<tr><th style=\"text-align: center;\"><input type=\"submit\" value=\"#{value}\"></th></tr>"  # Raw Input Value
  end
  def generate_form_textarea(res, label, name, value: '', style: '')
    res.body << "<tr><th><label>#{label}</label></th><td><textarea name=\"#{name}\" style=\"#{style}\">#{value}</textarea></tr>"  # Raw Input Value
  end
  def generate_signin(res, message: nil)
    generate_html_header(res, title: 'Sign In')
    generate_body_header(res, title: 'Sign In')
    generate_error_dialog(res, message) if message
    res.body << '<div class="signin">'
    generate_form(res, '/session') do
      generate_form_hidden(res, 'action', 'signin')
      generate_form_input(res, 'Username', 'username')
      generate_form_input(res, 'Password', 'password', type: 'password')
      generate_form_submit(res, 'Sign In')
    end
    res.body << '<br><a class="nav" href="/session?action=signup">Sign up</a> if you have no account.'
    res.body << '</div>'
    generate_html_footer(res)
  end
  def generate_signup(res, message: nil)
    generate_html_header(res, title: 'Sign Up')
    generate_body_header(res, title: 'Sign Up')
    generate_error_dialog(res, message) if message
    res.body << '<div class="signup">'
    generate_form(res, '/session') do
      generate_form_hidden(res, 'action', 'signup')
      generate_form_input(res, 'Username', 'username')
      generate_form_input(res, 'Password', 'password', type: 'password')
      generate_form_submit(res, 'Sign Up')
    end
    res.body << '<br><a class="nav" href="/session?action=signin">Sign in</a> if you have an account.'
    res.body << '</div>'
    generate_html_footer(res)
  end

  def handler_calendar(req, res)
    generate_404_not_found(res) unless req.path == '/calendar'
    session = get_session(req)
    generate_302_found(res, '/session?action=signin') unless session
    action = req.query['action']
    case action
    when 'create', 'delete', 'edit'
      cid = req.query['cid']
      calname = req.query['calname']
      color = req.query['color']
      errmsg = nil
      if req.query['confirm'] then
        begin
          case action
          when 'create'
            @db.create_calendar(calname, session[:user][:uid], color: color)
          when 'delete'
            @db.delete_calendar(cid)
          when 'edit'
            @db.edit_calendar(cid, calname, color)
          end
        rescue
          errmsg = $!
        end
        generate_302_found(res, '/calendar?action=list') unless errmsg
      end
      if action == 'edit' or action == 'delete' then
        cal = @db.select_calendar(cid)
        generate_302_found(res, '/calendar?action=list') unless cal
        calname = cal[:calname] if not req.query['calname'] or req.query['calname'] == ''
        color = cal[:color] if not req.query['color'] or req.query['color'] == ''
      end
      generate_html_header(res, title: "#{action.capitalize} Calendar")
      generate_body_header(res, title: "#{action.capitalize} Calendar", usermsg: generate_usermsg(session[:user][:username]))
      generate_error_dialog(res, errmsg) if errmsg
      res.body << "<div class=\"calendar-edit\">"
      generate_form(res, '/calendar') do
        generate_form_hidden(res, 'action', action)
        generate_form_hidden(res, 'cid', cid) if cid
        generate_form_input(res, 'Calendar Name', 'calname', value: calname, style: 'width: 40em;')
        generate_form_select(res, 'Color', 'color') do
          Database.palette.each do |col|
            generate_form_select_option(res, col.capitalize, col, selected: col == color)
          end
        end
        generate_form_hidden(res, 'confirm', '')
        generate_form_submit(res, action.capitalize)
      end
      res.body << "<br><a class=\"nav\" href=\"/calendar?action=delete&cid=#{cid}&confirm\">Delete Calendar</a>" if cid
      res.body << '</div>'
      generate_html_footer(res)
    when 'list'
      generate_html_header(res, title: 'Calendar List')
      generate_body_header(res, title: 'Calendar List', usermsg: generate_usermsg(session[:user][:username]))
      calendars = @db.select_calendars(session[:user][:uid])
      calendars.each do |cal|
        res.body << '<div>'
        res.body << "<a class=\"nav\" href=\"/calendar?action=edit&cid=#{cal[:cid]}\">[EDIT]</a>"
        res.body << "&nbsp; <span class=\"#{cal[:color]}\">&#11044;</span>"
        res.body << "&nbsp; <span class=\"title\">#{cal[:calname]}</span>"  # Raw Input Value
        res.body << '</div>'
      end
      res.body << '<div><a class="nav" href="/calendar?action=create">Create Calendar</a></div>'
      generate_html_footer(res)
    else
      generate_302_found(res, '/calendar?action=list')
    end
  end
  def handler_event(req, res)
    generate_404_not_found(res) unless req.path == '/event'
    session = get_session(req)
    generate_302_found(res, '/session?action=signin') unless session
    action = req.query['action']
    case action
    when 'create', 'delete', 'edit'
      eid = req.query['eid']
      cid = req.query['cid']
      start_at = parse_datetime(req.query['startAt'] || '')
      finish_at = parse_datetime(req.query['finishAt'] || '')
      title = req.query['title'] || ''
      content = req.query['content'] || ''
      errmsg = nil
      if req.query['confirm'] then
        begin
          case action
          when 'create'
            @db.create_event(cid, session[:user][:uid], start_at, finish_at, title, content)
          when 'delete'
            @db.delete_event(eid)
          when 'edit'
            @db.edit_event(eid, cid, start_at, finish_at, title, content)
          end
        rescue
          errmsg = $!
        end
        generate_302_found(res, "/?date=#{datetime_to_s(start_at)}") unless errmsg
      end
      if action == 'edit' or action == 'delete' then
        action = 'edit'
        event = if eid then @db.select_event(eid) end
        generate_302_found(res, "/") unless event
        cid = event[:cid] if not req.query['cid'] or req.query['cid'] == ''
        start_at = timestamp_to_datetime(event[:start_at]) if not req.query['startAt'] or req.query['startAt'] == ''
        finish_at = timestamp_to_datetime(event[:finish_at]) if not req.query['finishAt'] or req.query['finishAt'] == ''
        title = event[:title] if title == ''
        content = event[:content] if content == ''
      end
      generate_html_header(res, title: "#{action.capitalize} Event")
      generate_body_header(res, title: "#{action.capitalize} Event", usermsg: generate_usermsg(session[:user][:username]))
      generate_error_dialog(res, errmsg) if errmsg
      res.body << "<div class=\"event-edit\">"
      generate_form(res, '/event') do
        generate_form_hidden(res, 'action', action)
        generate_form_hidden(res, 'eid', eid) if eid
        calendars = @db.select_calendars(session[:user][:uid])
        generate_form_select(res, 'Calendar', 'cid') do
          calendars.each do |cal|
            generate_form_select_option(res, cal[:calname], cal[:cid], selected: cal[:cid] == cid)
          end
        end
        generate_form_input(res, 'Start At', 'startAt', value: datetime_to_s(start_at), type: 'datetime-local')
        generate_form_input(res, 'Finish At', 'finishAt', value: datetime_to_s(finish_at), type: 'datetime-local')
        generate_form_input(res, 'Title', 'title', value: title, style: 'width: 40em;')
        generate_form_textarea(res, 'Content', 'content', value: content, style: 'height: 5em; width: 40em;')
        generate_form_hidden(res, 'confirm', '')
        generate_form_submit(res, action.capitalize)
      end
      res.body << "<br><a class=\"nav\" href=\"/event?action=delete&eid=#{eid}&confirm\">Delete Event</a>" if eid
      res.body << '</div>'
      generate_html_footer(res)
    else
      generate_404_not_found(res)
    end
  end
  def handler_index(req, res)
    generate_404_not_found(res) unless req.path == '/'
    session = get_session(req)
    generate_302_found(res, '/session?action=signin') unless session
    date = req.query['date']
    date = if date then DateTime.parse(date) else DateTime.now end
    result = get_result(session[:user][:uid], date)
    generate_html_header(res, title: "#{result[:days][0][:date].year}/#{result[:days][0][:date].month}")
    generate_body_header(res, title: "#{result[:days][0][:date].year}/#{result[:days][0][:date].month}", usermsg: generate_usermsg(session[:user][:username]))
    res.body << '<nav>'
    res.body << "<a class=\"nav\" href=\"/?date=#{datetime_to_s(result[:prevweek_date])}\">&lt;</a>"
    res.body << " <a class=\"nav\" href=\"/\">Today</a>"
    res.body << " <a class=\"nav\" href=\"/?date=#{datetime_to_s(result[:nextweek_date])}\">&gt;</a>"
    res.body << '</nav>'
    res.body << '<table class="calendar"><tbody>'
    result[:days].each do |day|
      res.body << "<tr><th>"
      date = day[:date]
      wday_str = wday_to_s(date.wday)
      res.body << "<img src=\"res/icon#{wday_str}.png\" alt=\"icon#{wday_str}\" style=\"height: 6em;\"><br>"
      res.body << "<span class=\"wday-#{wday_str.downcase}\">#{date.day}(#{wday_str})</span>"
      add_start_at = DateTime.new(date.year, date.month, date.day, 9, 0, 0)
      add_finish_at = DateTime.new(date.year, date.month, date.day, 10, 0, 0)
      res.body << " <a class=\"nav\" href=\"/event?action=create&startAt=#{datetime_to_s(add_start_at)}&finishAt=#{datetime_to_s(add_finish_at)}\">[ADD]</a>"
      res.body << "</th><td>"
      day[:events].each do |event|
        start_at, finish_at = timestamp_to_datetime(event[:start_at]), timestamp_to_datetime(event[:finish_at])
        start_at_str = if start_at.to_date == date.to_date then time_to_s(start_at) end
        finish_at_str = if finish_at.to_date == date.to_date then time_to_s(finish_at) end
        time_str = if (start_at_str or finish_at_str) and start_at_str != '00:00' then "#{start_at_str}-#{finish_at_str}" else 'All Day' end
        res.body << "<div class=\"event event-#{event[:color]}\">"
        res.body << "<span class=\"event-title\">#{event[:title]}</span> <a class=\"event-link\" href=\"/event?action=edit&eid=#{event[:eid]}\">[EDIT]</a><br>"  # Raw Input Value
        res.body << "<span class=\"event-time\">#{time_str}</span> <span class=\"event-calname\">(#{event[:calname]})</span></div>"  # Raw Input Value
      end
      res.body << '</td></tr>'
    end
    res.body << '</tbody></table>'
    generate_html_footer(res)
  end
  def handler_session(req, res)
    generate_404_not_found(res) unless req.path == '/session'
    case req.query['action']
    when 'signin'
      session = get_session(req)
      if session then
        discard_session(res, session)
        generate_302_found(res, '/session?action=signin')
      end
      username, password = req.query['username'], req.query['password']
      generate_signin(res) unless username and password
      user = @db.select_user(username)
      generate_signin(res, message: 'Wrong Username or Password') unless user and user[:password] == password
      create_session(res, user)
      generate_302_found(res, '/')
    when 'signout'
      session = get_session(req)
      discard_session(res, session) if session
      generate_302_found(res, '/session?action=signin')
    when 'signup'
      session = get_session(req)
      if session then
        discard_session(res, session)
        generate_302_found(res, '/session?action=signup')
      end
      username, password = req.query['username'], req.query['password']
      generate_signup(res) unless username and password
      user = @db.select_user(username)
      generate_signup(res, message: 'Username is already used.') if user
      user = @db.signup_user(username, password)
      create_session(res, user)
      generate_302_found(res, '/')
    else
      generate_404_not_found(res)
    end
  end
end

# Open or initialize database.
Kama.logger.info("SQLite3 version: #{SQLite3::SQLITE_VERSION}")
DBPATH = ENV['DBPATH'] || File.join('.', 'dump', 'weakdays.db')
Kama.logger.info("opening database #{DBPATH} ...")
db = Database.new(DBPATH)
if not db.table_exists?('calendars') then
  Kama.logger.info("creating table calendars ...")
  db.create_table_calendars
end
if not db.table_exists?('events') then
  Kama.logger.info("creating table events ...")
  db.create_table_events
end
if not db.table_exists?('users') then
  Kama.logger.info("creating table users ...")
  db.create_table_users
  db.signup_user('admin', 'password')  # Weak Default Password
end

# Initialize the server.
# Users can see the unrescued exceptions.
SERVADDR = ENV['SERVADDR'] || '127.0.0.1'
SERVPORT = ENV['SERVPORT'] || '9090'
RESPATH = ENV['RESPATH'] || File.join(File.dirname(__FILE__), 'res')
server = Server.new(db, RESPATH, SERVADDR, SERVPORT)
server.start

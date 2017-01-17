require 'sinatra'

require './helpers/sinatra_ssl.rb'

# we default to production env b/c i want to
if ENV['RACK_ENV'].nil?
  set :environment, :production
  ENV['RACK_ENV'] = 'production'
end

require 'sinatra/flash'
require 'haml'
require 'data_mapper'
require './model/master.rb'
require 'json'
require 'redis'
require 'resque'
require './jobs/jobq.rb'
require './helpers/hash_importer'
require './helpers/hc_stdout_parser.rb'
require './helpers/email.rb'
require 'pony'

set :bind, '0.0.0.0'

# Check to see if SSL cert is present, if not generate
unless File.exist?('cert/server.crt')
  # Generate Cert
  system('openssl req -x509 -nodes -days 365 -newkey RSA:2048 -subj "/CN=US/ST=Minnesota/L=Duluth/O=potatoFactory/CN=hashview" -keyout cert/server.key -out cert/server.crt')
end

set :ssl_certificate, 'cert/server.crt'
set :ssl_key, 'cert/server.key'
enable :sessions

#redis = Redis.new

# validate every session
before /^(?!\/(login|register|logout))/ do
  if !validSession?
    redirect to('/login')
  else
    settings = Settings.first
    if (settings && settings.hcbinpath.nil?) || settings.nil?
      flash[:warning] = "Annoying alert! You need to define hashcat\'s binary path in settings first. Do so <a href=/settings>HERE</a>"
    end
  end
end

get '/login' do
  @users = User.all
  if @users.empty?
    redirect('/register')
  else
    haml :login
  end
end

get '/logout' do
  varWash(params)
  if session[:session_id]
    sess = Sessions.first(session_key: session[:session_id])
    sess.destroy if sess
  end
  redirect to('/')
end

post '/login' do
  varWash(params)
  if !params[:username] || params[:username].nil?
    flash[:error] = 'You must supply a username.'
    redirect to('/login')
  end

  if !params[:password] || params[:password].nil?
    flash[:error] = 'You must supply a password.'
    redirect to('/login')
  end

  @user = User.first(username: params[:username])

  if @user
    usern = User.authenticate(params['username'], params['password'])

    # if usern and session[:session_id]
    unless usern.nil?
      # only delete session if one exists
      if session[:session_id]
        # replace the session in the session table
        # TODO : This needs an expiration, session fixation
        @del_session = Sessions.first(username: usern)
        @del_session.destroy if @del_session
      end
      # Create new session
      @curr_session = Sessions.create(username: usern, session_key: session[:session_id])
      @curr_session.save

      redirect to('/home')
    end
    flash[:error] = 'Invalid credentials.'
    redirect to('/login')
  else
    flash[:error] = 'Invalid credentials.'
    redirect to('/login')
  end
end

get '/protected' do
  return 'This is a protected page, you must be logged in.'
end

get '/not_authorized' do
  return 'You are not authorized.'
end

get '/' do
  @users = User.all
  if @users.empty?
    redirect to('/register')
  elsif !validSession?
    redirect to('/login')
  else
    redirect to('/home')
  end
end

############################

### Register controllers ###

get '/register' do
  @users = User.all

  # Prevent registering of multiple admins
  redirect to('/') unless @users.empty?

  haml :register
end

post '/register' do
  varWash(params)
  if !params[:username] || params[:username].nil? || params[:username].empty?
    flash[:error] = 'You must have a username.'
    redirect to('/register')
  end

  if !params[:password] || params[:password].nil? || params[:password].empty?
    flash[:error] = 'You must have a password.'
    redirect to('/register')
  end

  if !params[:confirm] || params[:confirm].nil? || params[:confirm].empty?
    flash[:error] = 'You must have a password.'
    redirect to('/register')
  end

  # validate that no other user account exists
  @users = User.all
  if @users.empty?
    if params[:password] != params[:confirm]
      flash[:error] = 'Passwords do not match.'
      redirect to('/register')
    else
      new_user = User.new
      new_user.username = params[:username]
      new_user.password = params[:password]
      new_user.email = params[:email] unless params[:email].nil? || params[:email].empty?
      new_user.admin = 't'
      new_user.save
      flash[:success] = "User #{params[:username]} created successfully"
    end
  end

  redirect to('/login')
end

############################

##### Home controllers #####

get '/home' do
  if isOldVersion
    return "You need to perform some upgrade steps. Check instructions <a href=\"https://github.com/hashview/hashview/wiki/Upgrading-Hashview\">here</a>"
  end
  @results = `ps awwux | grep -i Hashcat | egrep -v "(grep|screen|SCREEN|resque|^$)"`
  @jobs = Jobs.all(:order => [:id.asc])
  @jobtasks = Jobtasks.all
  @tasks = Tasks.all

  @recentlycracked = repository(:default).adapter.select('SELECT CONCAT(timestampdiff(minute, h.lastupdated, NOW()) ) AS time_period, h.plaintext, a.username FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE (h.cracked = 1) ORDER BY h.lastupdated DESC LIMIT 10')

  @customers = Customers.all
  @active_jobs = Jobs.all(fields: [:id, :status], status: 'Running') | Jobs.all(fields: [:id, :status], status: 'Importing') 

  # nvidia works without sudo:
  @gpustatus = `nvidia-settings -q \"GPUCoreTemp\" | grep Attribute | grep -v gpu | awk '{print $3,$4}'`
  if @gpustatus.empty?
    @gpustatus = `lspci | grep "VGA compatible controller" | cut -d: -f3 | sed 's/\(rev a1\)//g'`
  end
  @gpustatus = @gpustatus.split("\n")
  @gpustat = []
  @gpustatus.each do |line|
    unless line.chomp.empty?
      line = line.delete('.')
      @gpustat << line
    end
  end

  @jobs.each do |j|
    if j.status == 'Running'
      # gather info for statistics

      @hash_ids = Array.new
      Hashfilehashes.all(fields: [:hash_id], hashfile_id: j.hashfile_id).each do |entry|
        @hash_ids.push(entry.hash_id)
      end
 
      @alltargets = Hashes.count(id: @hash_ids)
      @crackedtargets = Hashes.count(id: @hash_ids, cracked: 1)

      @progress = (@crackedtargets.to_f / @alltargets.to_f) * 100
      # parse a hashcat status file
      @hashcat_status = hashcatParser('control/outfiles/hcoutput_' + j.id.to_s + '.txt')
    end
  end

  haml :home
end

############################

### customer controllers ###

## Moved to routes/customers.rb

############################

### Account controllers ####

## Moved to routes/accounts.rb

############################

##### task controllers #####

## Moved to routes/tasks.rb

############################

##### job controllers #####

## Moved to routes/jobs.rb

############################

##### Global Settings ######

## Moved to routes/settings.rb

############################

##### Tests ################

get '/test/email' do

  account = User.first(username: getUsername)
  if account.email.nil? or account.email.empty?
    flash[:error] = 'Current logged on user has no email address associated.'
    redirect to('/settings')
  end

  if ENV['RACK_ENV'] != 'test'
    sendEmail(account.email, "Greetings from hashview", "This is a test message from hashview")
  end

  flash[:success] = 'Email sent.'

  redirect to('/settings')
end

############################

##### Downloads ############

get '/download' do
  varWash(params)

  if params[:customer_id] && !params[:customer_id].empty?
    if params[:hashfile_id] && !params[:hashfile_id].nil?

      # Until we can figure out JOIN statments, we're going to have to hack it
      @filecontents = Set.new
      Hashfilehashes.all(fields: [:id], hashfile_id: params[:hashfile_id]).each do |entry|
        if params[:type] == 'cracked' and Hashes.first(fields: [:cracked], id: entry.hash_id).cracked
          if entry.username.nil? # no username
            line = ''
          else
            line = entry.username + ':'
          end
          line = line + Hashes.first(fields: [:originalhash], id: entry.hash_id).originalhash
          line = line + ':' + Hashes.first(fields: [:plaintext], id: entry.hash_id, cracked: 1).plaintext
          @filecontents.add(line)
        elsif params[:type] == 'uncracked' and not Hashes.first(fields: [:cracked], id: entry.hash_id).cracked
          if entry.username.nil? # no username
            line = ''
          else
            line = entry.username + ':'
          end
          line = line + Hashes.first(fields: [:originalhash], id: entry.hash_id).originalhash
          @filecontents.add(line)
        end
      end
    else
      @filecontents = Set.new
      @hashfiles_ids = Hashfiles.all(fields: [:id], customer_id: params[:customer_id]).each do |hashfile|
        Hashfilehashes.all(fields: [:id], hashfile_id: hashfile.id).each do |entry|
          if params[:type] == 'cracked' and Hashes.first(fields: [:cracked], id: entry.hash_id).cracked
            if entry.username.nil? # no username
              line = ''
            else
              line = entry.username + ':'
            end
            line = line + Hashes.first(fields: [:originalhash], id: entry.hash_id).originalhash
            line = line + ':' + Hashes.first(fields: [:plaintext], id: entry.hash_id, cracked: 1).plaintext
            @filecontents.add(line)
          elsif params[:type] == 'uncracked' and not Hashes.first(fields: [:cracked], id: entry.hash_id).cracked
            if entry.username.nil? # no username
              line = ''
            else
              line = entry.username + ':'
            end
            line = line + Hashes.first(fields: [:originalhash], id: entry.hash_id).originalhash
            @filecontents.add(line)
          end
        end    
      end
    end
  else
    @filecontents = Set.new
    @hashfiles_ids = Hashfiles.all(fields: [:id]).each do |hashfile|
      Hashfilehashes.all(fields: [:id], hashfile_id: hashfile.id).each do |entry|
        if params[:type] == 'cracked' and Hashes.first(fields: [:cracked], id: entry.hash_id).cracked
          if entry.username.nil? # no username
            line = ''
          else
            line = entry.username + ':'
          end
          line = line + Hashes.first(fields: [:originalhash], id: entry.hash_id).originalhash
          line = line + ':' + Hashes.first(fields: [:plaintext], id: entry.hash_id, cracked: 1).plaintext
          @filecontents.add(line)
        elsif params[:type] == 'uncracked' and not Hashes.first(fields: [:cracked], id: entry.hash_id).cracked
          if entry.username.nil? # no username
            line = ''
          else
            line = entry.username + ':'
          end
          line = line + Hashes.first(fields: [:originalhash], id: entry.hash_id).originalhash
          @filecontents.add(line)
        end
      end
    end
  end

  # Write temp output file
  if params[:customer_id] && !params[:customer_id].empty?
    if params[:hashfile_id] && !params[:hashfile_id].nil?
      file_name = "found_#{params[:customer_id]}_#{params[:hashfile_id]}.txt" if params[:type] == 'cracked'
      file_name = "left_#{params[:customer_id]}_#{params[:hashfile_id]}.txt" if params[:type] == 'uncracked'
    else
      file_name = "found_#{params[:customer_id]}.txt" if params[:type] == 'cracked'
      file_name = "left_#{params[:customer_id]}.txt" if params[:type] == 'uncracked'
    end
  else
    file_name = 'found_all.txt' if params[:type] == 'cracked'
    file_name = 'left_all.txt' if params[:type] == 'uncracked'
  end

  file_name = 'control/outfiles/' + file_name

  File.open(file_name, 'w') do |f|
    @filecontents.each do |entry|
      f.puts entry
    end
  end

  send_file file_name, filename: file_name, type: 'Application/octet-stream'
end

############################

##### Word Lists ###########

## moved to routes/wordlists.rb

############################

##### Hash Lists ###########

get '/hashfiles/list' do
  @customers = Customers.all(order: [:name.asc])
  @hashfiles = Hashfiles.all
  @cracked_status = Hash.new
  @hashfiles.each do |hashfile|
    hashfile_cracked_count = repository(:default).adapter.select('SELECT COUNT(h.originalhash) FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE (a.hashfile_id = ? AND h.cracked = 1)', hashfile.id)[0].to_s
    hashfile_total_count = repository(:default).adapter.select('SELECT COUNT(h.originalhash) FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE a.hashfile_id = ?', hashfile.id)[0].to_s
    @cracked_status[hashfile.id] = hashfile_cracked_count.to_s + "/" + hashfile_total_count.to_s
  end

  haml :hashfile_list
end

get '/hashfiles/delete' do
  varWash(params)
  
  repository(:default).adapter.select('DELETE hashes FROM hashes LEFT JOIN hashfilehashes ON hashes.id = hashfilehashes.hash_id WHERE (hashfilehashes.hashfile_id = ? AND hashes.cracked = 0)', params[:hashfile_id])

  @hashfilehashes = Hashfilehashes.all(hashfile_id: params[:hashfile_id])
  @hashfilehashes.destroy unless @hashfilehashes.empty?

  @hashfile = Hashfiles.first(id: params[:hashfile_id])
  @hashfile.destroy unless @hashfile.nil?

  flash[:success] = 'Successfuly removed hashfile.'

  redirect to('/hashfiles/list')
end

############################

##### Analysis #############

# displays analytics for a specific client, job
get '/analytics' do
  varWash(params)

  @customer_id = params[:customer_id]
  @hashfile_id = params[:hashfile_id]
  @button_select_customers = Customers.all(order: [:name.asc])

  if params[:customer_id] && !params[:customer_id].empty?
    @button_select_hashfiles = Hashfiles.all(customer_id: params[:customer_id])
  end

  if params[:customer_id] && !params[:customer_id].empty?
    @customers = Customers.first(id: params[:customer_id])
  else
    @customers = Customers.all(order: [:name.asc])
  end

  if params[:customer_id] && !params[:customer_id].empty?
    if params[:hashfile_id] && !params[:hashfile_id].empty?
      @hashfiles = Hashfiles.first(id: params[:hashfile_id])
    else
      @hashfiles = Hashfiles.all
    end
  end

  # get results of specific customer if customer_id is defined
  # if we have a customer
  if params[:customer_id] && !params[:customer_id].empty?
    # if we have a hashfile
    if params[:hashfile_id] && !params[:hashfile_id].empty?
      # Used for Total Hashes Cracked doughnut: Customer: Hashfile
      @cracked_pw_count = repository(:default).adapter.select('SELECT COUNT(h.originalhash) FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE (a.hashfile_id = ? AND h.cracked = 1)', params[:hashfile_id])[0].to_s
      @uncracked_pw_count = repository(:default).adapter.select('SELECT COUNT(h.originalhash) FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE (a.hashfile_id = ? AND h.cracked = 0)', params[:hashfile_id])[0].to_s

      # Used for Total Accounts table: Customer: Hashfile
      @total_accounts = @uncracked_pw_count.to_i + @cracked_pw_count.to_i

      # Used for Total Unique Users and originalhashes Table: Customer: Hashfile
      @total_users_originalhash = repository(:default).adapter.select('SELECT a.username, h.originalhash FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE (f.customer_id = ? AND f.id = ?)', params[:customer_id],params[:hashfile_id])

      @total_unique_users_count = repository(:default).adapter.select('SELECT COUNT(DISTINCT(username)) FROM hashfilehashes WHERE hashfile_id = ?', params[:hashfile_id])[0].to_s
      @total_unique_originalhash_count = repository(:default).adapter.select('SELECT COUNT(DISTINCT(h.originalhash)) FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE a.hashfile_id = ?', params[:hashfile_id])[0].to_s

      # Used for Total Run Time: Customer: Hashfile
      @total_run_time = Hashfiles.first(fields: [:total_run_time], id: params[:hashfile_id]).total_run_time

      # make list of unique hashes
      unique_hashes = Set.new
      @total_users_originalhash.each do |entry|
        unique_hashes.add(entry.originalhash)
      end

      hashes = []
      # create array of all hashes to count dups
      @total_users_originalhash.each do |uh|
        unless uh.originalhash.nil?
          hashes << uh.originalhash unless uh.originalhash.empty?
        end
      end

      @duphashes = {}
      # count dup hashes
      hashes.each do |hash|
        if @duphashes[hash].nil?
          @duphashes[hash] = 1
        else
          @duphashes[hash] += 1
        end
      end
      # this will only display top 10 hash/passwords shared by users
      @duphashes = Hash[@duphashes.sort_by { |_k, v| -v }[0..20]]

      users_same_password = []
      @password_users = {}
      # for each unique password hash find the users and their plaintext
      @duphashes.each do |hash|
        dups = repository(:default).adapter.select('SELECT a.username, h.plaintext, h.cracked FROM hashes h LEFT JOIN hashfilehashes a on h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE (f.customer_id = ? AND f.id = ? AND h.originalhash = ?)', params[:customer_id], params[:hashfile_id], hash[0] )
        # for each user with the same password hash add user to array
        dups.each do |d|
          if !d.username.nil?
            users_same_password << d.username
          else
            users_same_password << 'NULL'
          end
          if d.cracked
            hash[0] = d.plaintext
          end
        end
        # assign array of users to hash of similar password hashes
        if users_same_password.length > 1
          @password_users[hash[0]] = users_same_password
        end
        users_same_password = []
      end

    else
      # Used for Total Hashes Cracked doughnut: Customer
      @cracked_pw_count = repository(:default).adapter.select('SELECT count(h.plaintext) FROM hashes h LEFT JOIN hashfilehashes a on h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE (f.customer_id = ? AND h.cracked = 1)', params[:customer_id])[0].to_s
      @uncracked_pw_count = repository(:default).adapter.select('SELECT count(h.originalhash) FROM hashes h LEFT JOIN hashfilehashes a on h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE (f.customer_id = ? AND h.cracked = 0)', params[:customer_id])[0].to_s

      # Used for Total Accounts Table: Customer
      @total_accounts = @uncracked_pw_count.to_i + @cracked_pw_count.to_i

      # Used for Total Unique Users and original hashes Table: Customer
      @total_unique_users_count = repository(:default).adapter.select('SELECT COUNT(DISTINCT(username)) FROM hashfilehashes a LEFT JOIN hashfiles f ON a.hashfile_id = f.id WHERE f.customer_id = ?', params[:customer_id])[0].to_s
      @total_unique_originalhash_count = repository(:default).adapter.select('SELECT COUNT(DISTINCT(h.originalhash)) FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id LEFT JOIN hashfiles f ON a.hashfile_id = f.id WHERE f.customer_id = ?', params[:customer_id])[0].to_s

      # Used for Total Run Time: Customer:
      @total_run_time = Hashfiles.sum(:total_run_time, conditions: { :customer_id => params[:customer_id] })
    end
  else
    # Used for Total Hash Cracked Doughnut: Total
    @cracked_pw_count = Hashes.count(cracked: 1)
    @uncracked_pw_count = Hashes.count(cracked: 0)

    # Used for Total Accounts Table: Total
    @total_accounts = Hashfilehashes.count

    # Used for Total Unique Users and originalhashes Tables: Total
    @total_unique_users_count = repository(:default).adapter.select('SELECT COUNT(DISTINCT(username)) FROM hashfilehashes')[0].to_s
    @total_unique_originalhash_count = repository(:default).adapter.select('SELECT COUNT(DISTINCT(originalhash)) FROM hashes')[0].to_s

    # Used for Total Run Time:
    @total_run_time = Hashfiles.sum(:total_run_time)
  end

  @passwords = @cracked_results.to_json

  haml :analytics
end

# callback for d3 graph displaying passwords by length
get '/analytics/graph1' do
  varWash(params)

  @counts = []
  @passwords = {}

  if params[:customer_id] && !params[:customer_id].empty?
    if params[:hashfile_id] && !params[:hashfile_id].empty?
      @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE h.cracked = 1 AND a.hashfile_id = ?', params[:hashfile_id])
    else
      @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE h.cracked = 1 AND f.customer_id = ?', params[:customer_id])
    end
  else
    @cracked_results = repository(:default).adapter.select('SELECT plaintext FROM hashes WHERE cracked = 1')
  end

  @cracked_results.each do |crack|
    unless crack.nil?
      unless crack.length == 0
        len = crack.length
        if @passwords[len].nil?
          @passwords[len] = 1
        else
          @passwords[len] = @passwords[len].to_i + 1
        end
      end
    end
  end

  # Sort on key
  @passwords = @passwords.sort.to_h

  # convert to array of json objects for d3
  @passwords.each do |key, value|
    @counts << { length: key, count: value }
  end

  return @counts.to_json
end

# callback for d3 graph displaying top 10 passwords
get '/analytics/graph2' do
  varWash(params)

  # This could probably be replaced with: SELECT COUNT(a.hash_id) AS frq, h.plaintext FROM hashfilehashes a LEFT JOIN hashes h ON h.id =  a.hash_id WHERE h.cracked = '1' GROUP BY a.hash_id ORDER BY frq DESC LIMIT 10;

  plaintext = []
  if params[:customer_id] && !params[:customer_id].empty?
    if params[:hashfile_id] && !params[:hashfile_id].empty?
      @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE h.cracked = 1 AND a.hashfile_id = ?', params[:hashfile_id])
    else
      @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE h.cracked = 1 AND f.customer_id = ?', params[:customer_id])
    end
  else
    @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE h.cracked = 1')
  end

  @cracked_results.each do |crack|
    unless crack.nil?
      plaintext << crack unless crack.empty?
    end
  end

  @toppasswords = []
  @top10passwords = {}
  # get top 10 passwords
  plaintext.each do |pass|
    if @top10passwords[pass].nil?
      @top10passwords[pass] = 1
    else
      @top10passwords[pass] += 1
    end
  end

  # sort and convert to array of json objects for d3
  @top10passwords = @top10passwords.sort_by { |_key, value| value }.reverse.to_h
  # we only need top 10
  @top10passwords = Hash[@top10passwords.sort_by { |_k, v| -v }[0..9]]
  # convert to array of json objects for d3
  @top10passwords.each do |key, value|
    @toppasswords << { password: key, count: value }
  end

  return @toppasswords.to_json
end

# callback for d3 graph displaying top 10 base words
get '/analytics/graph3' do
  varWash(params)

  plaintext = []
  if params[:customer_id] && !params[:customer_id].empty?
    if params[:hashfile_id] && !params[:hashfile_id].empty?
      @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE h.cracked = 1 AND a.hashfile_id = ?', params[:hashfile_id])
    else
      @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id WHERE h.cracked = 1 AND f.customer_id = ?', params[:customer_id])
    end
  else
    @cracked_results = repository(:default).adapter.select('SELECT h.plaintext FROM hashes h LEFT JOIN hashfilehashes a ON h.id = a.hash_id WHERE h.cracked = 1')
  end
  @cracked_results.each do |crack|
    unless crack.nil?
      plaintext << crack unless crack.empty?
    end
  end

  @topbasewords = []
  @top10basewords = {}
  # get top 10 basewords
  plaintext.each do |pass|
    word_just_alpha = pass.gsub(/^[^a-z]*/i, '').gsub(/[^a-z]*$/i, '')
    unless word_just_alpha.nil? or word_just_alpha.empty?
      if @top10basewords[word_just_alpha].nil?
        @top10basewords[word_just_alpha] = 1
      else
        @top10basewords[word_just_alpha] += 1
      end
    end
  end

  # sort and convert to array of json objects for d3
  @top10basewords = @top10basewords.sort_by { |_key, value| value }.reverse.to_h
  # we only need top 10
  @top10basewords = Hash[@top10basewords.sort_by { |_k, v| -v }[0..9]]
  # convert to array of json objects for d3
  @top10basewords.each do |key, value|
    @topbasewords << { password: key, count: value }
  end

  return @topbasewords.to_json
end

############################

##### search ###############

get '/search' do
  haml :search
end

post '/search' do
  varWash(params)
  @customers = Customers.all

  if params[:value].nil? || params[:value].empty?
    flash[:error] = 'Please provide a search term'
    redirect to('/search')
  end

  if params[:search_type].to_s == 'password'
    @results = repository(:default).adapter.select('SELECT a.username, h.plaintext, h.originalhash, h.hashtype, c.name FROM hashes h LEFT JOIN hashfilehashes a on h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id LEFT JOIN customers c ON f.customer_id = c.id WHERE h.plaintext like ?', params[:value])
  elsif params[:search_type].to_s == 'username'
    @results = repository(:default).adapter.select('SELECT a.username, h.plaintext, h.originalhash, h.hashtype, c.name FROM hashes h LEFT JOIN hashfilehashes a on h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id LEFT JOIN customers c ON f.customer_id = c.id WHERE a.username like ?', params[:value])
  elsif params[:search_type] == 'hash'
    @results = repository(:default).adapter.select('SELECT a.username, h.plaintext, h.originalhash, h.hashtype, c.name FROM hashes h LEFT JOIN hashfilehashes a on h.id = a.hash_id LEFT JOIN hashfiles f on a.hashfile_id = f.id LEFT JOIN customers c ON f.customer_id = c.id WHERE h.originalhash like ?', params[:value])
  end

  haml :search_post
end

############################

# Helper Functions

# Are we in development mode?
def isDevelopment?
  Sinatra::Base.development?
end

# Return if the user has a valid session or not
def validSession?
  Sessions.isValid?(session[:session_id])
end

# Get the current users, username
def getUsername
  Sessions.getUsername(session[:session_id])
end

# Check if the user is an administrator
def isAdministrator?
  return true if Sessions.type(session[:session_id])
end

# this function builds the main hashcat cmd we use to crack. this should be moved to a helper script soon
def buildCrackCmd(job_id, task_id)
  # order of opterations -m hashtype -a attackmode is dictionary? set wordlist, set rules if exist file/hash
  settings = Settings.first
  hcbinpath = settings.hcbinpath
  maxtasktime = settings.maxtasktime
  @task = Tasks.first(id: task_id)
  @job = Jobs.first(id: job_id)
  hashfile_id = @job.hashfile_id
  hash_id = Hashfilehashes.first(hashfile_id: hashfile_id).hash_id
  hashtype = Hashes.first(id: hash_id).hashtype.to_s

  attackmode = @task.hc_attackmode.to_s
  mask = @task.hc_mask

  if attackmode == 'combinator'
    wordlist_list = @task.wl_id
    @wordlist_list_elements = wordlist_list.split(',')
    wordlist_one = Wordlists.first(id: @wordlist_list_elements[0])
    wordlist_two = Wordlists.first(id: @wordlist_list_elements[1])
  else
    wordlist = Wordlists.first(id: @task.wl_id)
  end

  target_file = 'control/hashes/hashfile_' + job_id.to_s + '_' + task_id.to_s + '.txt'

  # we assign and write output file before hashcat.
  # if hashcat creates its own output it does so with
  # elvated permissions and we wont be able to read it
  crack_file = 'control/outfiles/hc_cracked_' + @job.id.to_s + '_' + @task.id.to_s + '.txt'
  File.open(crack_file, 'w')

  if attackmode == 'bruteforce'
    cmd = hcbinpath + ' -m ' + hashtype + ' --potfile-disable' + ' --status-timer=15' + ' --runtime=' + maxtasktime + ' --outfile-format 3 ' + ' --outfile ' + crack_file + ' ' + ' -a 3 ' + target_file + ' -w 3'
  elsif attackmode == 'maskmode'
    cmd = hcbinpath + ' -m ' + hashtype + ' --potfile-disable' + ' --status-timer=15' + ' --outfile-format 3 ' + ' --outfile ' + crack_file + ' ' + ' -a 3 ' + target_file + ' ' + mask + ' -w 3'
  elsif attackmode == 'dictionary'
    if @task.hc_rule == 'none'
      cmd = hcbinpath + ' -m ' + hashtype + ' --potfile-disable' + ' --status-timer=15' + ' --outfile-format 3 ' + ' --outfile ' + crack_file + ' ' + target_file + ' ' + wordlist.path + ' -w 3'
    else
      cmd = hcbinpath + ' -m ' + hashtype + ' --potfile-disable' + ' --status-timer=15' + ' --outfile-format 3 ' + ' --outfile ' + crack_file + ' ' + ' -r ' + 'control/rules/' + @task.hc_rule + ' ' + target_file + ' ' + wordlist.path + ' -w 3'
    end
  elsif attackmode == 'combinator'
    cmd = hcbinpath + ' -m ' + hashtype + ' --potfile-disable' + ' --status-timer=15' + '--outfile-format 3 ' + ' --outfile ' + crack_file + ' ' + ' -a 1 ' + target_file + ' ' + wordlist_one.path + ' ' + ' ' + wordlist_two.path + ' ' + @task.hc_rule.to_s + ' -w 3'
  end
  p cmd
  cmd
end

# Check if a job running
def isBusy?
  @results = `ps awwux | grep -i Hashcat | egrep -v "(grep|sudo|resque|^$)"`
  return true if @results.length > 1
end

def assignTasksToJob(tasks, job_id)
  tasks.each do |task_id|
    jobtask = Jobtasks.new
    jobtask.job_id = job_id
    jobtask.task_id = task_id
    jobtask.save
  end
end

def isOldVersion()
  begin
    if Targets.all
      return true
    else
      return false
    end
  rescue
    # we really need a better upgrade process
    return false
  end
end

helpers do
  def login?
    if session[:username].nil?
      return false
    else
      return true
    end
  end

  def username
    session[:username]
  end

  # Take you to the var wash baby
  def varWash(params)
    params.keys.each do |key|
      if params[key].is_a?(String)
        params[key] = cleanString(params[key])
      end
      if params[key].is_a?(Array)
        params[key] = cleanArray(params[key])
      end
    end
  end

  def cleanString(text)
    return text.gsub(/[<>'"()\/\\]*/i, '') unless text.nil?
  end

  def cleanArray(array)
    clean_array = []
    array.each do |entry|
      clean_array.push(cleanString(entry))
    end
    return clean_array
  end
end

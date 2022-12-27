describe 'activerecord-mysql-reconnect' do
  before(:each) do
    ActiveRecord::Base.establish_connection(
      :adapter  => 'mysql2',
      :host     => '127.0.0.1',
      :username => 'root',
      :database => 'employees',
      :port     => 14407,
    )

    ActiveRecord::Base.logger = Logger.new($stdout)
    ActiveRecord::Base.logger.formatter = proc {|_, _, _, message| "#{message}\n" }

    if ENV['DEBUG'] == '1'
      ActiveRecord::Base.logger.level = Logger::DEBUG
    else
      ActiveRecord::Base.logger.level = Logger::ERROR
    end

    ActiveRecord::Base.enable_retry = true
    ActiveRecord::Base.execution_tries = 10
    ActiveRecord::Base.retry_mode = :rw
    ActiveRecord::Base.retry_databases = []
  end

  let(:insert_with_sleep) do
    <<-SQL
      INSERT INTO `employees` (
        `birth_date`,
        `emp_no`,
        `first_name`,
        `hire_date`,
        `last_name`
      ) VALUES (
        '2014-01-09 03:22:25',
        SLEEP(10),
        'Scott',
        '2014-01-09 03:22:25',
        'Tiger'
      )
    SQL
  end

  context 'when select all on same thread' do
    specify do
      expect(Employee.all.length).to eq 1000
      MysqlServer.restart
      expect(Employee.all.length).to eq 1000
    end
  end

  context 'when count on same thead' do
    specify do
      expect(Employee.count).to eq 1000
      MysqlServer.restart
      expect(Employee.count).to eq 1000
    end
  end

  context 'when select on other thread' do
    specify do
      th = thread_start {
        result = ActiveRecord::Base.connection.execute("select SLEEP(10) * 0 + 3 from employees where id = 1")
        expect(result.first).to eq [3]
      }

      MysqlServer.restart
      expect(Employee.count).to eq 1000
      th.join
    end
  end

  context 'when insert on other thread' do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('MySQL server has gone away')
    end

    specify do
      th = thread_start {
        emp = Employee.create(
          :emp_no     => 9999,
          :birth_date => Time.now,
          # wait 10 sec
          :first_name => "' + sleep(10) + '",
          :last_name  => 'Tiger',
          :hire_date  => Time.now
        )
        expect(emp.id).to eq 1001
        expect(emp.emp_no).to eq 9999
      }

      MysqlServer.restart
      th.join
    end
  end

  [
    'MySQL server has gone away',
    'Server shutdown in progress',
    'closed MySQL connection',
    "Can't connect to MySQL server",
    'Query execution was interrupted',
    'Access denied for user',
    'The MySQL server is running with the --read-only option',
    "Can't connect to local MySQL server", # When running in local sandbox, or using a socket file
    'Unknown MySQL server host', # For DNS blips
    "Lost connection to MySQL server at 'reading initial communication packet'",
  ].each do |errmsg|
    context "when `#{errmsg}` is happened" do
      before do
        allow_any_instance_of(Mysql2::Error).to receive(:message).and_return(errmsg)
      end

      specify do
        th = thread_start {
          emp = Employee.create(
            :emp_no     => 9999,
            :birth_date => Time.now,
            # wait 10 sec
            :first_name => "' + sleep(10) + '",
            :last_name  => 'Tiger',
            :hire_date  => Time.now
          )

          expect(emp.id).to eq 1001
          expect(emp.emp_no).to eq 9999
        }

        MysqlServer.restart
        th.join
      end
    end
  end

  context 'when unexpected error is happened' do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return("unexpected error")
    end

    specify do
      th = thread_start {
        expect {
          emp = Employee.create(
            :emp_no     => 9999,
            :birth_date => Time.now,
            # wait 10 sec
            :first_name => "' + sleep(10) + '",
            :last_name  => 'Tiger',
            :hire_date  => Time.now
          )
        }.to raise_error(/unexpected error/)
      }

      MysqlServer.restart
      th.join
    end
  end

  context 'when update on other thread' do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('MySQL server has gone away')
    end

    specify do
      th = thread_start {
        emp = Employee.where(:id => 1).first
        # wait 10 sec
        emp.first_name = "' + sleep(10) + '"
        emp.last_name = 'ZapZapZap'
        emp.save!

        emp = Employee.where(:id => 1).first
        expect(emp.last_name).to eq 'ZapZapZap'
      }

      MysqlServer.restart
      th.join
    end
  end

  context 'when use #without_retry' do
    specify do
      expect {
        ActiveRecord::Base.without_retry do
          Employee.count
          MysqlServer.restart
          Employee.count
        end
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  context 'with transaction' do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('MySQL server has gone away')
    end

    specify do
      skip if myisam?

      expect(Employee.count).to eq 1000

      ActiveRecord::Base.transaction do
        emp = Employee.create(
          :emp_no     => 9999,
          :birth_date => Time.now,
          :first_name => 'Scott',
          :last_name  => 'Tiger',
          :hire_date  => Time.now
        )

        expect(emp.id).to eq 1001
        expect(emp.emp_no).to eq 9999
        expect(Employee.all.count).to eq 1001

        # NOTE: restartでcommit前のinsertが無視される?
        MysqlServer.restart

        emp = Employee.create(
          :emp_no     => 9998,
          :birth_date => Time.now,
          :first_name => 'Scott',
          :last_name  => 'Tiger',
          :hire_date  => Time.now
        )
        expect(Employee.all.count).to eq 1001
        expect(emp.emp_no).to eq 9998
      end

      expect(Employee.count).to eq 1001
    end
  end

  context 'when new connection' do
    specify do
      ActiveRecord::Base.clear_all_connections!
      MysqlServer.restart
      expect(Employee.count).to eq 1000
    end
  end

  context 'when connection verify' do
    specify do
      th = thread_start {
        MysqlServer.stop
        sleep 10
        MysqlServer.start
      }

      sleep 5
      ActiveRecord::Base.connection.verify!
      th.join
    end
  end

  context 'when connection reconnect' do
    specify do
      th = thread_start {
        MysqlServer.stop
        sleep 10
        MysqlServer.start
      }

      sleep 5
      ActiveRecord::Base.connection.reconnect!
      th.join
    end
  end

  context 'when disable reconnect' do
    specify do
      ActiveRecord::Base.enable_retry = false

      expect {
        expect(Employee.all.length).to eq 1000
        MysqlServer.restart
        expect(Employee.all.length).to eq 1000
      }.to raise_error(ActiveRecord::StatementInvalid)

      ActiveRecord::Base.enable_retry = true

      expect(Employee.all.length).to eq 1000
      MysqlServer.restart
      expect(Employee.all.length).to eq 1000
    end
  end

  context 'when select on :r mode' do
    before do
      ActiveRecord::Base.retry_mode = :r
    end

    specify do
      expect(Employee.all.length).to eq 1000
      MysqlServer.restart
      expect(Employee.all.length).to eq 1000
    end
  end

  context 'when insert on :r mode' do
    before do
      ActiveRecord::Base.retry_mode = :r
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('MySQL server has gone away')
    end

    specify do
      expect(Employee.all.length).to eq 1000

      MysqlServer.restart

      expect {
        Employee.create(
          :emp_no     => 9999,
          :birth_date => Time.now,
          # wait 10 sec
          :first_name => "' + sleep(10) + '",
          :last_name  => 'Tiger',
          :hire_date  => Time.now
        )
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  context 'when `lost connection` is happened' do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('Lost connection to MySQL server during query')
    end

    specify do
      expect(Employee.all.length).to eq 1000

      MysqlServer.restart

      expect {
        Employee.create(
          :emp_no     => 9999,
          :birth_date => Time.now,
          # wait 10 sec
          :first_name => "' + sleep(10) + '",
          :last_name  => 'Tiger',
          :hire_date  => Time.now
        )
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  context 'when `lost connection` is happened on :force mode' do
    before do
      ActiveRecord::Base.retry_mode = :force
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('Lost connection to MySQL server during query')
    end

    specify do
      expect(Employee.all.length).to eq 1000

      MysqlServer.restart

      emp = Employee.create(
        :emp_no     => 9999,
        :birth_date => Time.now,
        # wait 10 sec
        :first_name => "' + sleep(10) + '",
        :last_name  => 'Tiger',
        :hire_date  => Time.now
      )

      expect(emp.id).to eq 1001
      expect(emp.emp_no).to eq 9999
    end
  end

  context 'when `lost connection` is happened on :force mode (2)' do
    before do
      ActiveRecord::Base.retry_mode = :force
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('Lost connection to MySQL server during query')

      Thread.start do
        MysqlServer.lock_tables
      end
    end

    specify do
      th = thread_start {
        ActiveRecord::Base.connection.execute(insert_with_sleep)
      }

      sleep 3
      MysqlServer.restart
      th.join
    end
  end

  context 'when read-only=1' do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('The MySQL server is running with the --read-only option so it cannot execute this statement:')
    end

    specify do
      expect(Employee.all.length).to eq 1000
      MysqlServer.restart
      expect(Employee.all.length).to eq 1000
    end
  end

  [
    :employees2,
    '127.0.0.2:employees',
    '127.0.0.\_:employees',
  ].each do |db|
    context "when retry specific database: #{db}" do
      before do
        ActiveRecord::Base.retry_databases = db
      end

      specify do
        expect {
          expect(Employee.all.length).to eq 1000
          MysqlServer.restart
          expect(Employee.all.length).to eq 1000
        }.to raise_error(ActiveRecord::StatementInvalid)

        ActiveRecord::Base.retry_databases = []

        expect(Employee.all.length).to eq 1000
        MysqlServer.restart
        expect(Employee.all.length).to eq 1000
      end
    end
  end

  [
    :employees,
    '127.0.0.1:employees',
    '127.0.0._:e%',
  ].each do |db|
    context "when retry specific database: #{db}" do
      before do
        ActiveRecord::Base.retry_databases = db
      end

      specify do
        expect(Employee.all.length).to eq 1000
        MysqlServer.restart
        expect(Employee.all.length).to eq 1000
      end
    end
  end

  context "when retry with warning" do
    let(:warning_template) do
      "%s (cause: %s, sql: SELECT `employees`.* FROM `employees`, connection: host=127.0.0.1;database=employees;username=root)"
    end

    let(:mysql_error) do
      Mysql2::Error::ConnectionError
    end

    let(:connection_error_message) do
        # @see: https://github.com/rails/rails/blob/1beb0ff2061f7f61e7f0c3773d35b87835df7d9f/activerecord/lib/active_record/errors.rb#L76
        <<~MSG
          There is an issue connecting with your hostname: 127.0.0.1.\n
          Please check your database configuration and ensure there is a valid connection to your database.
        MSG
    end

    before do
      allow_any_instance_of(mysql_error).to receive(:message).and_return('Lost connection to MySQL server during query')
    end

    context "when retry failed " do
      specify do
        # 一度目はコネクションが存在するため
        expect(ActiveRecord::Base.logger).to receive(:warn).with(warning_template % [
          "MySQL server has gone away. Trying to reconnect in 0.5 seconds.",
          "#{mysql_error}: Lost connection to MySQL server during query [ActiveRecord::StatementInvalid]",
        ])


        (1.0..4.5).step(0.5).each do |sec|
          expect(ActiveRecord::Base.logger).to receive(:warn).with(warning_template % [
            "MySQL server has gone away. Trying to reconnect in #{sec} seconds.",
            "#{connection_error_message} [ActiveRecord::DatabaseConnectionError]",
          ])
        end

        expect(ActiveRecord::Base.logger).to receive(:warn).with(warning_template % [
          "Query retry failed.",
          "#{connection_error_message} [ActiveRecord::DatabaseConnectionError]",
        ])

        expect(Employee.all.length).to eq 1000
        MysqlServer.stop

        expect {
          Employee.all.length
        }.to raise_error(ActiveRecord::DatabaseConnectionError)
      end
    end

    context "when retry succeeded" do
      specify do
        if ActiveRecord::VERSION::MAJOR < 6
          expect(ActiveRecord::Base.logger).to receive(:warn).with(warning_template % [
            "MySQL server has gone away. Trying to reconnect in 0.5 seconds.",
            "#{mysql_error}: Lost connection to MySQL server during query: SELECT `employees`.* FROM `employees` [ActiveRecord::StatementInvalid]",
          ])
        else
          expect(ActiveRecord::Base.logger).to receive(:warn).with(warning_template % [
            "MySQL server has gone away. Trying to reconnect in 0.5 seconds.",
            "#{mysql_error}: Lost connection to MySQL server during query [ActiveRecord::StatementInvalid]",
          ])
        end

        expect(Employee.all.length).to eq 1000
        MysqlServer.restart
        expect(Employee.all.length).to eq 1000
      end
    end
  end

  # NOTE: The following test need to execute at the last
  context "when the custom error is happened" do
    before do
      allow_any_instance_of(Mysql2::Error).to receive(:message).and_return('ZapZapZap')
      Activerecord::Mysql::Reconnect.handle_rw_error_messages.update(zapzapzap: 'ZapZapZap')
    end

    specify do
      th = thread_start {
        emp = Employee.create(
          :emp_no     => 9999,
          :birth_date => Time.now,
          # wait 10 sec
          :first_name => "' + sleep(10) + '",
          :last_name  => 'Tiger',
          :hire_date  => Time.now
        )

        expect(emp.id).to eq 1001
        expect(emp.emp_no).to eq 9999
      }

      MysqlServer.restart
      th.join
    end
  end
end

# frozen_string_literal: true

RSpec.describe "SQLite implementation integrity#{ENV['AR_VERSION'] ? " (AR v#{ENV['AR_VERSION']})" : ''}" do
  subject do
    callback = proc { |_, _, _, _, payload| query_parts << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed callback, 'sql.active_record' do
      query
    end
    query_parts
  end

  let(:query_parts) { [] }

  describe 'wrapped in transaction', timecop: Time.zone.parse('2018-08-09 10:00:00 UTC') do
    describe '.find_or_create_by' do
      let(:query) { DummySqliteRecord.find_or_create_by(name: 'a name') { |r| r.unique_name = '1' } }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          match(
            [
              'begin transaction',
              'SELECT "dummy_sqlite_records".* FROM "dummy_sqlite_records" WHERE "dummy_sqlite_records"."name" = \'a name\' LIMIT 1',
              a_string_including('INSERT INTO "dummy_sqlite_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'1\', \'2018-08-09 10:00:00\')'),
              'commit transaction'
            ]
          )
        )
      end
    end

    describe 'wrapping using wrap_in_trx along with explicit class name' do
      let(:dummy_class) do
        Class.new do
          class << self
            def find_or_create_by(attributes, &block)
              DummySqliteRecord.find_by(attributes) || DummySqliteRecord.create(attributes, &block)
            end
            wrap_in_trx :find_or_create_by, 'DummySqliteRecord'
          end
        end

      end
      let(:query) { dummy_class.find_or_create_by(name: 'a name') { |r| r.unique_name = '1' } }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          match(
            [
              'begin transaction',
              'SELECT "dummy_sqlite_records".* FROM "dummy_sqlite_records" WHERE "dummy_sqlite_records"."name" = \'a name\' LIMIT 1',
              a_string_including('INSERT INTO "dummy_sqlite_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'1\', \'2018-08-09 10:00:00\')'),
              'commit transaction'
            ]
          )
        )
      end
    end

    describe '.find_or_create_by!' do
      let(:query) { DummySqliteRecord.find_or_create_by!(name: 'a name') { |r| r.unique_name = '1' } }

      it 'does not wrap SELECT and INSERT in same transaction when using non-atomic method' do
        is_expected.to(
          match(
            [
              'SELECT "dummy_sqlite_records".* FROM "dummy_sqlite_records" WHERE "dummy_sqlite_records"."name" = \'a name\' LIMIT 1',
              'begin transaction',
              a_string_including('INSERT INTO "dummy_sqlite_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'1\', \'2018-08-09 10:00:00\')'),
              'commit transaction'
            ]
          )
        )
      end
    end
  end

  describe 'retry until serialized with callbacks' do
    describe 'when error is raised in on_complete callback' do
      let(:error_class) { Class.new(StandardError) }
      let(:query) do
        i = 0
        DummySqliteRecord.trx do |c|
          DummySqliteRecord.first
          c.on_complete {
            i += 1
            raise(error_class.new("deadlock detected")) if i < 2
          }
        end
      end

      it 'does not catch the error with TrxExt::Retry.with_retry_until_serialized' do
        expect { subject }.to raise_error(error_class, /deadlock detected/)
      end
      it 'completes the transaction' do
        begin
          subject
        rescue error_class
        end
        expect(query_parts).to eq(
          [
            'begin transaction',
            'SELECT "dummy_sqlite_records".* FROM "dummy_sqlite_records" ORDER BY "dummy_sqlite_records"."id" ASC LIMIT 1',
            'commit transaction'
          ]
        )
      end
    end
  end

  describe 'query retry on ActiveRecord::RecordNotUnique exception' do
    let!(:dummy_record_1) { FactoryBot.create(:dummy_sqlite_record) }
    let!(:dummy_record_2) { FactoryBot.create(:dummy_sqlite_record) }
    let(:query) { dummy_record_2.update_columns(unique_name: dummy_record_1.unique_name) }

    it 'retries query up to TrxExt.config.unique_retries times' do
      begin
        subject
      rescue TrxExt::Retry::RetryLimitExceeded
      end

      expect(query_parts).to(
        eq(
          [
            "UPDATE \"dummy_sqlite_records\" SET \"unique_name\" = '#{dummy_record_1.unique_name}' WHERE \"dummy_sqlite_records\".\"id\" = #{dummy_record_2.id}"
          ] * (TrxExt.config.unique_retries + 1)
        )
      )
    end
  end

  describe 'Multi-thread integration' do
    subject do
      Array.new(concurrency) do
        query.call
      end.each { |_, thread, pid| thread.join; Process.waitpid(pid) }
    end

    let(:concurrency) { 1 }
    let(:cbx_1) { [] }
    let(:cbx_2) { [] }
    let(:cbx_3) { [] }
    let(:query) do
      proc do
        [
          DummySqliteRecord.trx do |c|
            dr = DummySqliteRecord.create(unique_name: "thread1-#{SecureRandom.hex(16)}")
            c.on_complete { dr.update(name: dr.unique_name) }
          end,
          Thread.new do
            DummySqliteRecord.trx do |c|
              dr = DummySqliteRecord.create(unique_name: "thread2-#{SecureRandom.hex(16)}")
              c.on_complete { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
          end,
          fork do
            DummySqliteRecord.trx do |c|
              dr = DummySqliteRecord.create(unique_name: "fork1-#{SecureRandom.hex(16)}")
              c.on_complete { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
            exit
          end
        ]
      end
    end

    it 'executes callbacks being run in the current thread the proper amount of times' do
      subject
      expect(DummySqliteRecord.where("unique_name like 'thread1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in another thread the proper amount of times' do
      subject
      expect(DummySqliteRecord.where("unique_name like 'thread2%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in the fork the proper amount of times' do
      subject
      expect(DummySqliteRecord.where("unique_name like 'fork1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'creates correct amount of records' do
      subject
      expect(DummySqliteRecord.count).to eq(concurrency * 3)
    end
  end
end

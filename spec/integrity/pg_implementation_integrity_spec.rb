# frozen_string_literal: true

RSpec.describe "PostgreSQL implementation integrity#{ENV['AR_VERSION'] ? " (AR v#{ENV['AR_VERSION']})" : ''}" do
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
      let(:query) { DummyPgRecord.find_or_create_by(name: 'a name') { |r| r.unique_name = '1' } }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          eq(
            [
              'BEGIN',
              'SELECT "dummy_pg_records".* FROM "dummy_pg_records" WHERE "dummy_pg_records"."name" = \'a name\' LIMIT 1',
              'INSERT INTO "dummy_pg_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'1\', \'2018-08-09 10:00:00\') RETURNING "id"',
              'COMMIT'
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
              DummyPgRecord.find_by(attributes) || DummyPgRecord.create(attributes, &block)
            end
            wrap_in_trx :find_or_create_by, 'DummyPgRecord'
          end
        end

      end
      let(:query) { dummy_class.find_or_create_by(name: 'a name') { |r| r.unique_name = '1' } }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          eq(
            [
              'BEGIN',
              'SELECT "dummy_pg_records".* FROM "dummy_pg_records" WHERE "dummy_pg_records"."name" = \'a name\' LIMIT 1',
              'INSERT INTO "dummy_pg_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'1\', \'2018-08-09 10:00:00\') RETURNING "id"',
              'COMMIT'
            ]
          )
        )
      end
    end

    describe '.find_or_create_by!' do
      let(:query) { DummyPgRecord.find_or_create_by!(name: 'a name') { |r| r.unique_name = '1' } }

      it 'does not wrap SELECT and INSERT in same transaction when using non-atomic method' do
        is_expected.to(
          eq(
            [
              'SELECT "dummy_pg_records".* FROM "dummy_pg_records" WHERE "dummy_pg_records"."name" = \'a name\' LIMIT 1',
              'BEGIN',
              'INSERT INTO "dummy_pg_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'1\', \'2018-08-09 10:00:00\') RETURNING "id"',
              'COMMIT'
            ]
          )
        )
      end
    end
  end

  describe 'retry until serialized', timecop: Time.zone.parse('2018-08-09 10:00:00 UTC') do
    let(:callback) { object_spy('callback') }
    let(:query) do
      DummyPgRecord.trx do |c|
        c.on_complete { callback.exec }
        DummyPgRecord.where(name: 'a name').exists?
        FactoryBot.create(:dummy_pg_record, name: 'a name', unique_name: '2')
        sleep 1
      end
    end

    before do
      allow(callback).to receive(:exec)
    end

    it 'retries query until serialized' do
      pid = fork do
        DummyPgRecord.trx do
          DummyPgRecord.where(name: 'a name').exists?
          FactoryBot.create(:dummy_pg_record, name: 'a name', unique_name: '1')
        end
        exit!
      end

      is_expected.to(
        eq(
          [
            'BEGIN',
            'SELECT 1 AS one FROM "dummy_pg_records" WHERE "dummy_pg_records"."name" = \'a name\' LIMIT 1',
            'INSERT INTO "dummy_pg_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'2\', \'2018-08-09 10:00:00\') RETURNING "id"',
            'COMMIT',
            'ROLLBACK',
            'BEGIN',
            'SELECT 1 AS one FROM "dummy_pg_records" WHERE "dummy_pg_records"."name" = \'a name\' LIMIT 1',
            'INSERT INTO "dummy_pg_records" ("name", "unique_name", "created_at") VALUES (\'a name\', \'2\', \'2018-08-09 10:00:00\') RETURNING "id"',
            'COMMIT'
          ]
        )
      )
      Process.waitpid(pid)
    end
    it 'executes callback only once' do
      subject
      expect(callback).to have_received(:exec).once
    end
  end

  describe 'retry until serialized with callbacks' do
    describe 'when error is raised in on_complete callback' do
      let(:error_class) { Class.new(StandardError) }
      let(:query) do
        i = 0
        DummyPgRecord.trx do |c|
          DummyPgRecord.first
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
            'BEGIN',
            'SELECT "dummy_pg_records".* FROM "dummy_pg_records" ORDER BY "dummy_pg_records"."id" ASC LIMIT 1',
            'COMMIT'
          ]
        )
      end
    end
  end

  describe 'query retry on ActiveRecord::RecordNotUnique exception' do
    let!(:dummy_record_1) { FactoryBot.create(:dummy_pg_record) }
    let!(:dummy_record_2) { FactoryBot.create(:dummy_pg_record) }
    let(:query) { dummy_record_2.update_columns(unique_name: dummy_record_1.unique_name) }

    it 'retries query up to TrxExt.config.unique_retries times' do
      begin
        subject
      rescue TrxExt::Retry::RetryLimitExceeded
      end
      expect(query_parts).to(
        eq(
          [
            "UPDATE \"dummy_pg_records\" SET \"unique_name\" = '#{dummy_record_1.unique_name}' WHERE \"dummy_pg_records\".\"id\" = #{dummy_record_2.id}"
          ] * (TrxExt.config.unique_retries + 1)
        )
      )
    end
  end

  describe 'Multi-process multi-thread integration' do
    subject do
      Array.new(concurrency) do
        query.call
      end.each { |_, thread, pid| thread.join; Process.waitpid(pid) }
    end

    let(:concurrency) { Etc.nprocessors }
    let(:cbx_1) { [] }
    let(:cbx_2) { [] }
    let(:cbx_3) { [] }
    let(:query) do
      proc do
        [
          DummyPgRecord.trx do |c|
            dr = DummyPgRecord.create(unique_name: "thread1-#{SecureRandom.hex(16)}")
            c.on_complete { dr.update(name: dr.unique_name) }
          end,
          Thread.new do
            DummyPgRecord.trx do |c|
              dr = DummyPgRecord.create(unique_name: "thread2-#{SecureRandom.hex(16)}")
              c.on_complete { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
          end,
          fork do
            DummyPgRecord.trx do |c|
              dr = DummyPgRecord.create(unique_name: "fork1-#{SecureRandom.hex(16)}")
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
      expect(DummyPgRecord.where("unique_name like 'thread1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in another thread the proper amount of times' do
      subject
      expect(DummyPgRecord.where("unique_name like 'thread2%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in the fork the proper amount of times' do
      subject
      expect(DummyPgRecord.where("unique_name like 'fork1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'creates correct amount of records' do
      subject
      expect(DummyPgRecord.count).to eq(concurrency * 3)
    end
  end
end

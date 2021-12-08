# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Transaction Integrity#{ENV['AR_VERSION'] ? " (AR v#{ENV['AR_VERSION']})" : ''}" do
  subject do
    callback = proc {|_, _, _, _, payload| query_parts << payload[:sql] unless payload[:name] == 'SCHEMA'}
    ActiveSupport::Notifications.subscribed callback, 'sql.active_record' do
      query
    end
    query_parts
  end

  let(:query_parts) { [] }

  describe 'wrapped in transaction', timecop: Time.zone.parse('2018-08-09 10:00:00 UTC') do
    describe '.find_or_create_by' do
      let(:query) { DummyRecord.find_or_create_by(name: 'a name') }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          eq(
            [
              'BEGIN',
              'SELECT "dummy_records".* FROM "dummy_records" WHERE "dummy_records"."name" = \'a name\' LIMIT 1',
              'INSERT INTO "dummy_records" ("name", "created_at") VALUES (\'a name\', \'2018-08-09 10:00:00\') RETURNING "id"',
              'COMMIT'
            ]
          )
        )
      end
    end

    describe '.find_or_create_by!' do
      let(:query) { DummyRecord.find_or_create_by!(name: 'a name') }

      it 'does not wrap SELECT and INSERT in same transaction when using non-atomic method' do
        is_expected.to(
          eq(
            [
              'SELECT "dummy_records".* FROM "dummy_records" WHERE "dummy_records"."name" = \'a name\' LIMIT 1',
              'BEGIN',
              'INSERT INTO "dummy_records" ("name", "created_at") VALUES (\'a name\', \'2018-08-09 10:00:00\') RETURNING "id"',
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
      trx do |c|
        c.on_complete { callback.exec }
        DummyRecord.where(name: 'a name').exists?
        DummyRecord.create(name: 'a name')
        sleep 1
      end
    end

    before do
      allow(callback).to receive(:exec)
    end

    it 'retries query until serialized' do
      pid = fork do
        trx do
          DummyRecord.where(name: 'a name').exists?
          DummyRecord.create(name: 'a name')
        end
        exit!
      end

      is_expected.to(
        eq(
          [
            'BEGIN',
            'SELECT 1 AS one FROM "dummy_records" WHERE "dummy_records"."name" = \'a name\' LIMIT 1',
            'INSERT INTO "dummy_records" ("name", "created_at") VALUES (\'a name\', \'2018-08-09 10:00:00\') RETURNING "id"',
            'COMMIT',
            'ROLLBACK',
            'BEGIN',
            'SELECT 1 AS one FROM "dummy_records" WHERE "dummy_records"."name" = \'a name\' LIMIT 1',
            'INSERT INTO "dummy_records" ("name", "created_at") VALUES (\'a name\', \'2018-08-09 10:00:00\') RETURNING "id"',
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
        trx do |c|
          DummyRecord.first
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
            'SELECT "dummy_records".* FROM "dummy_records" ORDER BY "dummy_records"."id" ASC LIMIT 1',
            'COMMIT'
          ]
        )
      end
    end
  end

  describe 'callbacks order' do
    # Not using :let here, because :let memorizes the result
    def callback_1; callbacks.push('cb1'); end
    def callback_2; callbacks.push('cb2'); end
    def callback_3_1; callbacks.push('cb3_1'); end
    def callback_3_2; callbacks.push('cb3_2'); end

    let(:callbacks) { [] }
    let(:query) do
      trx do |c1|
        DummyRecord.first
        c1.on_complete do
          callback_1
        end
        trx do |c2|
          c2.on_complete do
            callback_2
          end
          DummyRecord.find_by(id: 123)
          trx do |c3|
            DummyRecord.find_by(id: 321)
            c3.on_complete do
              callback_3_1
            end
            c3.on_complete do
              callback_3_2
            end
          end
        end
        DummyRecord.last
      end
    end

    it 'executes callbacks from the most inner transaction in stack' do
      subject
      expect(callbacks).to eq(%w(cb3_1 cb3_2 cb2 cb1))
    end
    it 'sets current_callbacks_chain_link to nil ' do
      subject
      expect(ActiveRecord::Base.connection.current_callbacks_chain_link).to be_nil
    end
  end

  describe 'callbacks order when transaction is called inside "on_complete" callback' do
    # Not using :let here, because :let memorizes the result
    def callback_1; callbacks.push('cb1'); end
    def callback_2; callbacks.push('cb2'); end
    def callback_3_1; callbacks.push('cb3_1'); end
    def callback_3_2; callbacks.push('cb3_2'); end
    def callback_4; callbacks.push('cb4'); end

    let(:callbacks) { [] }
    let(:query) do
      trx do |c1|
        DummyRecord.first
        c1.on_complete do
          callback_1
          trx do |c2|
            c2.on_complete do
              trx do |c3|
                DummyRecord.find_by(id: 321)
                c3.on_complete do
                  callback_3_1
                end
                c3.on_complete do
                  callback_3_2
                end
              end
              callback_2
            end
            DummyRecord.find_by(id: 123)
            trx do |c4|
              DummyRecord.find_by(id: 1234)
              c4.on_complete do
                callback_4
              end
            end
          end
        end
        DummyRecord.last
      end
    end

    it 'executes callbacks in mixed order(' do
      subject
      expect(callbacks).to eq(%w(cb1 cb4 cb3_1 cb3_2 cb2))
    end
    it 'sets current_callbacks_chain_link to nil ' do
      subject
      expect(ActiveRecord::Base.connection.current_callbacks_chain_link).to be_nil
    end
  end

  describe 'callback is inside another callback of same callbacks pool' do
    let(:callback) { object_spy('callback') }
    let(:query) do
      trx do |c1|
        DummyRecord.first
        c1.on_complete do
          trx do
            DummyRecord.last
            c1.on_complete do
              callback.exec
            end
          end
        end
      end
    end

    before do
      allow(callback).to receive(:exec)
    end

    it 'executes the callback' do
      subject
      expect(callback).to have_received(:exec)
    end
    it 'sets current_callbacks_chain_link to nil ' do
      subject
      expect(ActiveRecord::Base.connection.current_callbacks_chain_link).to be_nil
    end
  end

  describe 'query retry on ActiveRecord::RecordNotUnique exception' do
    let!(:dummy_record_1) { FactoryBot.create(:dummy_record) }
    let!(:dummy_record_2) { FactoryBot.create(:dummy_record) }
    let(:query) { dummy_record_2.update_columns(unique_name: dummy_record_1.unique_name) }

    it 'retries query up to TrxExt.config.unique_retries times' do
      begin
        subject
      rescue ActiveRecord::RecordNotUnique
      end
      expect(query_parts).to(
        eq(
          [
            "UPDATE \"dummy_records\" SET \"unique_name\" = '#{dummy_record_1.unique_name}' WHERE \"dummy_records\".\"id\" = #{dummy_record_2.id}"
          ] * TrxExt.config.unique_retries
        )
      )
    end
  end

  describe 'Multi-process multi-thread integration' do
    subject do
      Array.new(30) do
        query.call
      end.each { |_, thread, pid| thread.join; Process.waitpid(pid) }
    end

    let(:cbx_1) { [] }
    let(:cbx_2) { [] }
    let(:cbx_3) { [] }
    let(:query) do
      proc do
        [
          trx do |c|
            dr = DummyRecord.create(unique_name: "thread1-#{SecureRandom.hex(16)}")
            c.on_complete { dr.update(name: dr.unique_name) }
          end,
          Thread.new do
            trx do |c|
              dr = DummyRecord.create(unique_name: "thread2-#{SecureRandom.hex(16)}")
              c.on_complete { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
          end,
          fork do
            trx do |c|
              dr = DummyRecord.create(unique_name: "fork1-#{SecureRandom.hex(16)}")
              c.on_complete { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
          end
        ]
      end
    end

    it 'executes callbacks being run in the current thread the proper amount of times' do
      subject
      expect(DummyRecord.where("unique_name like 'thread1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in another thread the proper amount of times' do
      subject
      expect(DummyRecord.where("unique_name like 'thread2%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in the fork the proper amount of times' do
      subject
      expect(DummyRecord.where("unique_name like 'fork1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'creates correct amount of records' do
      subject
      expect(DummyRecord.count).to eq(90)
    end
  end
end

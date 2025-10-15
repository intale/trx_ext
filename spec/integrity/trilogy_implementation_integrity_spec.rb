# frozen_string_literal: true

RSpec.describe "Trilogy implementation integrity#{ENV['AR_VERSION'] ? " (AR v#{ENV['AR_VERSION']})" : ''}" do
  subject do
    callback = proc do |_, _, _, id, payload|
      query_parts << payload[:sql] unless payload[:name] == 'SCHEMA'
    end
    ActiveSupport::Notifications.subscribed callback, 'sql.active_record' do
      query
    end
    query_parts
  end

  let(:query_parts) { [] }

  describe 'wrapped in transaction', timecop: Time.zone.parse('2018-08-09 10:00:00 UTC') do
    describe '.find_or_create_by' do
      let(:query) { DummyTrilogyRecord.find_or_create_by(name: 'a name') { |r| r.unique_name = '1' } }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          eq(
            [
              'BEGIN',
              'SELECT `dummy_trilogy_records`.* FROM `dummy_trilogy_records` WHERE `dummy_trilogy_records`.`name` = \'a name\' LIMIT 1',
              'INSERT INTO `dummy_trilogy_records` (`created_at`, `name`, `unique_name`) VALUES (\'2018-08-09 10:00:00\', \'a name\', \'1\')',
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
              DummyTrilogyRecord.find_by(attributes) || DummyTrilogyRecord.create(attributes, &block)
            end
            wrap_in_trx :find_or_create_by, 'DummyTrilogyRecord'
          end
        end

      end
      let(:query) { dummy_class.find_or_create_by(name: 'a name') { |r| r.unique_name = '1' } }

      it 'wraps SELECT and INSERT in same transaction when using atomic method' do
        is_expected.to(
          eq(
            [
              'BEGIN',
              'SELECT `dummy_trilogy_records`.* FROM `dummy_trilogy_records` WHERE `dummy_trilogy_records`.`name` = \'a name\' LIMIT 1',
              'INSERT INTO `dummy_trilogy_records` (`created_at`, `name`, `unique_name`) VALUES (\'2018-08-09 10:00:00\', \'a name\', \'1\')',
              'COMMIT'
            ]
          )
        )
      end
    end

    describe '.find_or_create_by!' do
      let(:query) { DummyTrilogyRecord.find_or_create_by!(name: 'a name') { |r| r.unique_name = '1' } }

      it 'does not wrap SELECT and INSERT in same transaction when using non-atomic method' do
        is_expected.to(
          eq(
            [
              'SELECT `dummy_trilogy_records`.* FROM `dummy_trilogy_records` WHERE `dummy_trilogy_records`.`name` = \'a name\' LIMIT 1',
              'BEGIN',
              'INSERT INTO `dummy_trilogy_records` (`created_at`, `name`, `unique_name`) VALUES (\'2018-08-09 10:00:00\', \'a name\', \'1\')',
              'COMMIT'
            ]
          )
        )
      end
    end
  end

  describe 'retry until serialized', timecop: Time.zone.parse('2018-08-09 10:00:00 UTC') do
    let!(:dummy_record_1) { FactoryBot.create(:dummy_trilogy_record, unique_name: 'unique name 1') }
    let!(:dummy_record_2) { FactoryBot.create(:dummy_trilogy_record, unique_name: 'unique name 2') }
    let(:callback) { object_spy('callback') }
    let(:query) do
      DummyTrilogyRecord.trx do |t|
        t.after_commit { callback.exec }
        DummyTrilogyRecord.lock("FOR SHARE").find_by(unique_name: dummy_record_1.unique_name)
        sleep 1
        DummyTrilogyRecord.where(unique_name: dummy_record_2.unique_name).update_all(name: 'new 1')
      end
    end

    before do
      allow(callback).to receive(:exec)
    end

    it 'retries query until serialized' do
      pid = fork do
        DummyTrilogyRecord.trx do
          DummyTrilogyRecord.lock("FOR SHARE").find_by(unique_name: dummy_record_2.unique_name)
          DummyTrilogyRecord.where(unique_name: dummy_record_1.unique_name).update_all(name: 'new 2')
        end
      end
      subject
      Process.waitpid(pid)
      expect(subject).to(
        eq(
          [
            'BEGIN',
            "SELECT `dummy_trilogy_records`.* FROM `dummy_trilogy_records` WHERE `dummy_trilogy_records`.`unique_name` = 'unique name 1' LIMIT 1 FOR SHARE",
            "UPDATE `dummy_trilogy_records` SET `dummy_trilogy_records`.`name` = 'new 1' WHERE `dummy_trilogy_records`.`unique_name` = 'unique name 2'",
            'ROLLBACK',
            'BEGIN',
            "SELECT `dummy_trilogy_records`.* FROM `dummy_trilogy_records` WHERE `dummy_trilogy_records`.`unique_name` = 'unique name 1' LIMIT 1 FOR SHARE",
            "UPDATE `dummy_trilogy_records` SET `dummy_trilogy_records`.`name` = 'new 1' WHERE `dummy_trilogy_records`.`unique_name` = 'unique name 2'",
            'COMMIT'
          ]
        )
      )
    end
    it 'executes callback only once' do
      subject
      expect(callback).to have_received(:exec).once
    end
  end

  describe 'retry until serialized with callbacks' do
    describe 'when error is raised in after_commit callback' do
      let(:error_class) { Class.new(StandardError) }
      let(:query) do
        i = 0
        DummyTrilogyRecord.trx do |t|
          DummyTrilogyRecord.first
          t.after_commit {
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
            'SELECT `dummy_trilogy_records`.* FROM `dummy_trilogy_records` ORDER BY `dummy_trilogy_records`.`id` ASC LIMIT 1',
            'COMMIT'
          ]
        )
      end
    end
  end

  describe 'query retry on ActiveRecord::RecordNotUnique exception' do
    let!(:dummy_record_1) { FactoryBot.create(:dummy_trilogy_record) }
    let!(:dummy_record_2) { FactoryBot.create(:dummy_trilogy_record) }
    let(:query) { dummy_record_2.update_columns(unique_name: dummy_record_1.unique_name) }

    it 'retries query up to TrxExt.config.unique_retries times' do
      begin
        subject
      rescue ActiveRecord::RecordNotUnique
      end
      expect(query_parts).to(
        eq(
          [
            "UPDATE `dummy_trilogy_records` SET `dummy_trilogy_records`.`unique_name` = '#{dummy_record_1.unique_name}' WHERE `dummy_trilogy_records`.`id` = #{dummy_record_2.id}"
          ] * (TrxExt.config.unique_retries + 1)
        )
      )
    end
  end

  describe 'query retry on ActiveRecord::RecordNotUnique exception inside multiple transactions' do
    let!(:dummy_record_1) { FactoryBot.create(:dummy_trilogy_record) }
    let!(:dummy_record_2) { FactoryBot.create(:dummy_trilogy_record) }
    let(:query) do
      DummyTrilogyRecord.trx do
        DummyTrilogyRecord.trx do
          dummy_record_2.update_columns(unique_name: dummy_record_1.unique_name)
        end
      end
    end

    it 'retries query up to TrxExt.config.unique_retries times' do
      begin
        subject
      rescue ActiveRecord::RecordNotUnique
      end
      expect(query_parts).to(
        eq(
          [
            "BEGIN",
            "UPDATE `dummy_trilogy_records` SET `dummy_trilogy_records`.`unique_name` = '#{dummy_record_1.unique_name}' WHERE `dummy_trilogy_records`.`id` = #{dummy_record_2.id}",
            "ROLLBACK"
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
          DummyTrilogyRecord.trx do |t|
            dr = DummyTrilogyRecord.create(unique_name: "thread1-#{SecureRandom.hex(16)}")
            t.after_commit { dr.update(name: dr.unique_name) }
          end,
          Thread.new do
            DummyTrilogyRecord.trx do |t|
              dr = DummyTrilogyRecord.create(unique_name: "thread2-#{SecureRandom.hex(16)}")
              t.after_commit { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
          end,
          fork do
            DummyTrilogyRecord.trx do |t|
              dr = DummyTrilogyRecord.create(unique_name: "fork1-#{SecureRandom.hex(16)}")
              t.after_commit { dr.update(name: dr.unique_name) }
            end
            sleep 0.1
            exit!
          end
        ]
      end
    end

    it 'executes callbacks being run in the current thread the proper amount of times' do
      subject
      expect(DummyTrilogyRecord.where("unique_name like 'thread1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in another thread the proper amount of times' do
      subject
      expect(DummyTrilogyRecord.where("unique_name like 'thread2%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'executes callbacks being run in the fork the proper amount of times' do
      subject
      expect(DummyTrilogyRecord.where("unique_name like 'fork1%'").to_a).to all satisfy { |dr| dr.unique_name == dr.name }
    end
    it 'creates correct amount of records' do
      subject
      expect(DummyTrilogyRecord.count).to eq(concurrency * 3)
    end
  end
end

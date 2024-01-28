# frozen_string_literal: true

RSpec.describe "Callbacks implementation integrity#{ENV['AR_VERSION'] ? " (AR v#{ENV['AR_VERSION']})" : ''}" do
  shared_examples 'callbacks order' do
    let(:dummy_class) do
      Class.new do
        def initialize(callbacks)
          @callbacks = callbacks
        end
        def callback_1; @callbacks.push('cb1'); end
        def callback_2; @callbacks.push('cb2'); end
        def callback_3_1; @callbacks.push('cb3_1'); end
        def callback_3_2; @callbacks.push('cb3_2'); end
      end
    end
    let(:instance) { dummy_class.new(callbacks) }
    let(:callbacks) { [] }
    subject do
      ar_class.trx do |c1|
        ar_class.first
        c1.on_complete do
          instance.callback_1
        end
        ar_class.trx do |c2|
          c2.on_complete do
            instance.callback_2
          end
          ar_class.find_by(id: 123)
          ar_class.trx do |c3|
            ar_class.find_by(id: 321)
            c3.on_complete do
              instance.callback_3_1
            end
            c3.on_complete do
              instance.callback_3_2
            end
          end
        end
        ar_class.last
      end
    end

    it 'executes callbacks from the most inner transaction in stack' do
      subject
      expect(callbacks).to eq(%w(cb3_1 cb3_2 cb2 cb1))
    end
    it 'sets current_callbacks_chain_link to nil ' do
      subject
      aggregate_failures do
        expect(ActiveRecord::Base.connection.current_callbacks_chain_link).to be_nil
        expect(DummyPgRecord.connection.current_callbacks_chain_link).to be_nil
        expect(DummySqliteRecord.connection.current_callbacks_chain_link).to be_nil
      end
    end
  end

  shared_examples 'callbacks order when transaction is called inside "on_complete" callback' do
    let(:dummy_class) do
      Class.new do
        def initialize(callbacks)
          @callbacks = callbacks
        end
        def callback_1; @callbacks.push('cb1'); end
        def callback_2; @callbacks.push('cb2'); end
        def callback_3_1; @callbacks.push('cb3_1'); end
        def callback_3_2; @callbacks.push('cb3_2'); end
        def callback_4; @callbacks.push('cb4'); end
      end
    end
    let(:instance) { dummy_class.new(callbacks) }
    let(:callbacks) { [] }
    subject do
      ar_class.trx do |c1|
        ar_class.first
        c1.on_complete do
          instance.callback_1
          ar_class.trx do |c2|
            c2.on_complete do
              ar_class.trx do |c3|
                ar_class.find_by(id: 321)
                c3.on_complete do
                  instance.callback_3_1
                end
                c3.on_complete do
                  instance.callback_3_2
                end
              end
              instance.callback_2
            end
            ar_class.find_by(id: 123)
            ar_class.trx do |c4|
              ar_class.find_by(id: 1234)
              c4.on_complete do
                instance.callback_4
              end
            end
          end
        end
        ar_class.last
      end
    end

    it 'executes callbacks in mixed order(' do
      subject
      expect(callbacks).to eq(%w(cb1 cb4 cb3_1 cb3_2 cb2))
    end
    it 'sets current_callbacks_chain_link to nil ' do
      subject
      aggregate_failures do
        expect(ActiveRecord::Base.connection.current_callbacks_chain_link).to be_nil
        expect(DummyPgRecord.connection.current_callbacks_chain_link).to be_nil
        expect(DummySqliteRecord.connection.current_callbacks_chain_link).to be_nil
      end
    end
  end

  shared_examples 'callback is inside another callback of same callbacks pool' do
    let(:callback) { object_spy('callback') }
    subject do
      ar_class.trx do |c1|
        ar_class.first
        c1.on_complete do
          ar_class.trx do
            ar_class.last
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
      aggregate_failures do
        expect(ActiveRecord::Base.connection.current_callbacks_chain_link).to be_nil
        expect(DummyPgRecord.connection.current_callbacks_chain_link).to be_nil
        expect(DummySqliteRecord.connection.current_callbacks_chain_link).to be_nil
      end
    end
  end

  describe 'testing integration with PostgreSQL' do
    let(:ar_class) { DummyPgRecord }

    it_behaves_like 'callbacks order'
    it_behaves_like 'callbacks order when transaction is called inside "on_complete" callback'
    it_behaves_like 'callback is inside another callback of same callbacks pool'
  end

  describe 'testing integration with SQLite' do
    let(:ar_class) { DummySqliteRecord }

    it_behaves_like 'callbacks order'
    it_behaves_like 'callbacks order when transaction is called inside "on_complete" callback'
    it_behaves_like 'callback is inside another callback of same callbacks pool'
  end
end

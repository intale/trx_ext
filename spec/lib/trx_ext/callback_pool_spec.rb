# frozen_string_literal: true

RSpec.describe TrxExt::CallbackPool do
  let(:instance) { described_class.new }

  describe '.add' do
    subject { described_class.add(previous: previous) }

    let(:previous) { described_class.new }

    describe 'when previous is present' do
      it { is_expected.to be_a(described_class) }
      its(:previous) { is_expected.to eq(previous) }

      describe 'when previous is locked for execution' do
        before do
          previous.locked_for_execution = true
        end

        it 'does not assign #previous' do
          expect(subject.previous).to be_nil
        end
        it { is_expected.to be_a(described_class) }
      end
    end

    describe 'when "previous" is absent' do
      let(:previous) { nil }

      its(:previous) { is_expected.to be_nil }
    end
  end

  describe '#locked_for_execution?' do
    subject { instance.locked_for_execution? }

    describe 'when instance is not locked for execution' do
      it { is_expected.to eq(false) }
    end

    describe 'when instance is locked for execution' do
      before do
        instance.locked_for_execution = true
      end

      it { is_expected.to be_truthy }
    end
  end

  describe '#on_complete' do
    subject { instance.on_complete(&block) }

    let(:block) { proc { 'some block' } }

    it 'adds block to the callbacks list' do
      subject
      expect(instance.instance_variable_get(:@callbacks)).to eq([block])
    end
  end

  describe '#exec_callbacks_chain' do
    subject { instance.exec_callbacks_chain(connection: connection) }

    let(:connection) { ActiveRecord::Base.connection }

    before do
      allow(instance).to receive(:exec_callbacks)
      allow(connection).to receive(:current_callbacks_chain_link=).and_call_original
    end

    describe 'when #previous is present' do
      before do
        instance.previous = described_class.new
      end

      it { is_expected.to be_falsey }
      it 'does not call connection#current_callbacks_chain_link=' do
        subject
        expect(connection).not_to have_received(:current_callbacks_chain_link=)
      end
    end

    describe 'when #previous is nil' do
      let(:pool_1) { described_class.new }
      let(:pool_2) { described_class.new }

      before do
        pool_2.previous = pool_1
        pool_1.previous = instance
        allow(pool_1).to receive(:exec_callbacks)
        allow(pool_2).to receive(:exec_callbacks)
      end

      describe 'when connection#current_callbacks_chain_link is nil' do
        it { is_expected.to be_truthy }
        it 'does not exec callbacks of the instance' do
          subject
          expect(instance).not_to have_received(:exec_callbacks)
        end
        it 'does not exec callbacks of pool_1' do
          subject
          expect(pool_1).not_to have_received(:exec_callbacks)
        end
        it 'does not exec callbacks of pool_2' do
          subject
          expect(pool_2).not_to have_received(:exec_callbacks)
        end
        it 'does not lock pool_1 for execution' do
          subject
          expect(pool_1.locked_for_execution?).to be_falsey
        end
        it 'does not lock pool_2 for execution' do
          subject
          expect(pool_2.locked_for_execution?).to be_falsey
        end
        it 'calls connection#current_callbacks_chain_link=' do
          subject
          expect(connection).to have_received(:current_callbacks_chain_link=).with(nil)
        end
      end

      describe 'when connection#current_callbacks_chain_link is present' do
        before do
          connection.current_callbacks_chain_link = pool_2
        end

        it { is_expected.to be_truthy }
        it 'exec callbacks of the instance' do
          subject
          expect(instance).to have_received(:exec_callbacks)
        end
        it 'exec callbacks of pool_1' do
          subject
          expect(pool_1).to have_received(:exec_callbacks)
        end
        it 'exec callbacks of pool_2' do
          subject
          expect(pool_2).to have_received(:exec_callbacks)
        end
        it 'does locks pool_1 for execution' do
          subject
          expect(pool_1.locked_for_execution?).to be_truthy
        end
        it 'does locks pool_2 for execution' do
          subject
          expect(pool_2.locked_for_execution?).to be_truthy
        end
        it 'calls connection#current_callbacks_chain_link=' do
          subject
          expect(connection).to have_received(:current_callbacks_chain_link=).with(nil)
        end
      end

      describe 'when error raises' do
        let(:error_msg) { 'some error' }
        let(:error_class) { Class.new(StandardError) }

        before do
          connection.current_callbacks_chain_link = pool_2
          allow(pool_2).to receive(:exec_callbacks).and_raise(error_class, error_msg)
        end

        it 'raises that error' do
          expect { subject }.to raise_error(error_class, error_msg)
        end
        it 'calls #current_callbacks_chain_link=' do
          begin
            subject
          rescue error_class
          end
          expect(connection).to have_received(:current_callbacks_chain_link=).with(nil)
        end
      end
    end
  end

  describe '#exec_callbacks' do
    subject { instance.exec_callbacks }

    let(:callback_1) { object_spy('callback_1', exec: nil) }
    let(:callback_2) { object_spy('callback_2', exec: nil) }

    before do
      instance.on_complete { callback_1.exec }
      instance.on_complete { callback_2.exec }
    end

    it 'executes block with callback_1' do
      subject
      expect(callback_1).to have_received(:exec)
    end
    it 'executes block with callback_2' do
      subject
      expect(callback_2).to have_received(:exec)
    end
  end
end

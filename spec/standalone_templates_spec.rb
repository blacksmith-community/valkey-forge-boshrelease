require 'rspec'
require 'yaml'
require 'bosh/template/test'

describe 'standalone job templates' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('standalone') }
  let(:conf) { job.template('config/valkey.conf') }
  let(:bpm) { job.template('config/bpm.yml') }

  def directives(rendered, name)
    rendered.lines.map(&:strip).select { |l| l.split(/\s+/, 2).first == name }
  end

  def workdir(rendered)
    YAML.safe_load(rendered)['processes'].first['workdir']
  end

  context 'when persistent' do
    let(:props) { { 'auth' => { 'password' => 'x' }, 'persistent' => true } }

    it 'keeps the dataset in the persistent store' do
      expect(directives(conf.render(props), 'dir')).to eq(['dir /var/vcap/store/standalone'])
    end

    it 'runs valkey from the same directory' do
      expect(workdir(bpm.render(props))).to eq('/var/vcap/store/standalone')
    end

    it 'keeps the AOF on' do
      expect(directives(conf.render(props), 'appendonly')).to eq(['appendonly yes'])
    end
  end

  context 'when not persistent' do
    let(:props) { { 'auth' => { 'password' => 'x' }, 'persistent' => false } }

    it 'points dir at the writable ephemeral data directory' do
      expect(directives(conf.render(props), 'dir')).to eq(['dir /var/vcap/data/standalone'])
    end

    it 'runs valkey from the same directory' do
      expect(workdir(bpm.render(props))).to eq('/var/vcap/data/standalone')
    end

    it 'turns RDB snapshots off' do
      expect(directives(conf.render(props), 'save')).to eq(['save ""'])
    end

    it 'leaves the AOF off' do
      expect(directives(conf.render(props), 'appendonly')).to eq([])
    end
  end
end

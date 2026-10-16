require 'rspec'
require 'yaml'
require 'bosh/template/test'

describe 'valkey-blacksmith-plans classic plans' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('valkey-blacksmith-plans') }
  let(:base) { { 'environment' => 'lab', 'bosh_env' => 'lab' } }
  let(:tls) { base.merge('valkey' => { 'tls' => { 'enabled' => true, 'dual-mode' => false } }) }
  let(:plain) { base.merge('valkey' => { 'tls' => { 'enabled' => false, 'dual-mode' => false } }) }

  # plan => [instance group, job name] used by the plan manifest
  layout = { 'standalone' => %w[standalone standalone], 'cluster' => %w[node cluster] }

  def render(plan, file, props)
    job.template("plans/#{plan}/#{file}").render(props)
  end

  def creds(plan, props)
    YAML.safe_load(render(plan, 'credentials.yml', props))['credentials']
  end

  layout.each do |plan, (group, job_name)|
    classic = "#{plan}-classic"

    context "the #{classic} plan" do
      it 'renders the same manifest as the base plan' do
        expect(render(classic, 'manifest.yml', plain)).to eq(render(plan, 'manifest.yml', plain))
      end

      it 'runs the same init as the base plan' do
        expect(render(classic, 'init', plain)).to eq(render(plan, 'init', plain))
      end

      it 'leaves out the per-binding ACL trigger fields' do
        expect(creds(classic, plain).keys).not_to include('admin_password', 'service_type')
      end

      it 'hands out the shared password under the default user' do
        c = creds(classic, plain)
        expect(c).to include('password' => '(( grab meta.password ))', 'username' => 'default')
      end

      it 'keeps every other credential the base plan has' do
        expected = creds(plan, tls).keys - %w[admin_password service_type]
        expect(creds(classic, tls).keys).to match_array(expected)
      end

      it 'adds the instance CA when TLS is on' do
        ca = "(( grab instance_groups.#{group}.jobs.#{job_name}.properties.valkey.tls.ca ))"
        expect(creds(classic, tls)['ca_certificate']).to eq(ca)
      end

      it 'leaves the CA out when TLS is off' do
        expect(creds(classic, plain)).not_to have_key('ca_certificate')
      end
    end
  end
end

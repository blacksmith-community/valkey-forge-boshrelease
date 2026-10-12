require 'rspec'
require 'yaml'
require 'bosh/template/test'

describe 'valkey-blacksmith-plans binding credentials' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('valkey-blacksmith-plans') }
  let(:base) { { 'environment' => 'lab', 'bosh_env' => 'lab' } }
  let(:tls) { base.merge('valkey' => { 'tls' => { 'enabled' => true, 'dual-mode' => false } }) }
  let(:plain) { base.merge('valkey' => { 'tls' => { 'enabled' => false, 'dual-mode' => false } }) }

  # instance group and job names that each plan's manifest uses
  layout = { 'standalone' => %w[standalone standalone], 'cluster' => %w[node cluster] }

  def creds(plan, props)
    YAML.safe_load(job.template("plans/#{plan}/credentials.yml").render(props))['credentials']
  end

  def manifest(plan, props)
    YAML.safe_load(job.template("plans/#{plan}/manifest.yml").render(props), aliases: true)
  end

  layout.each do |plan, (group, job_name)|
    context "the #{plan} plan" do
      let(:ca_path) { "instance_groups.#{group}.jobs.#{job_name}.properties.valkey.tls.ca" }

      it 'adds the CA as ca_certificate when TLS is on' do
        expect(creds(plan, tls)['ca_certificate']).to eq("(( grab #{ca_path} ))")
      end

      it 'grabs a path that holds the CA the manifest gives the instance' do
        node = manifest(plan, tls)['instance_groups'].find { |g| g['name'] == group }
        props = node['jobs'].find { |j| j['name'] == job_name }['properties']
        expect(props.dig('valkey', 'tls', 'ca')).to eq(
          '(( file "/var/vcap/jobs/blacksmith/config/tls/blacksmith_services_ca" ))'
        )
      end

      it 'leaves the CA out when TLS is off' do
        expect(creds(plan, plain)).not_to have_key('ca_certificate')
      end

      it 'keeps every existing credential field' do
        keys = creds(plan, tls).keys
        expect(keys).to include('host', 'port', 'password', 'admin_password', 'username',
                                'service_type', 'tls_port', 'tls_versions')
      end
    end
  end
end

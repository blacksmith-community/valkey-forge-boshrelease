require 'rspec'
require 'yaml'
require 'bosh/template/test'

describe 'valkey-blacksmith-plans bpm release' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('valkey-blacksmith-plans') }
  let(:base) { { 'environment' => 'lab', 'bosh_env' => 'lab' } }

  def bpm_entry(rendered)
    YAML.safe_load(rendered, aliases: true)['releases'].find { |r| r['name'] == 'bpm' }
  end

  %w[standalone cluster].each do |plan|
    context "the #{plan} manifest" do
      let(:tmpl) { job.template("plans/#{plan}/manifest.yml") }

      it 'defaults to bpm 1.4.41' do
        expect(bpm_entry(tmpl.render(base))).to eq(
          'name' => 'bpm',
          'version' => '1.4.41',
          'url' => 'https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.4.41',
          'sha1' => 'sha256:7b445508d63d2171d892ba33f836087e1e519b9782f44c5fa5290323616ca8e6'
        )
      end

      it 'renders the bpm release from the job properties' do
        props = base.merge('bpm_release' => {
          'version' => '1.4.20',
          'url' => 'https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.4.20',
          'sha1' => 'sha256:1984129b352cd414e29a7dcffcf076049a776afa511cd44b587065f6e618cc6d'
        })
        expect(bpm_entry(tmpl.render(props))).to eq(
          'name' => 'bpm',
          'version' => '1.4.20',
          'url' => 'https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.4.20',
          'sha1' => 'sha256:1984129b352cd414e29a7dcffcf076049a776afa511cd44b587065f6e618cc6d'
        )
      end
    end
  end
end

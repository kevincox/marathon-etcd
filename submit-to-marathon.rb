#! /usr/bin/env ruby

require 'json'
require 'net/http'
require 'openssl'
require 'yaml'

pkg = ARGV.fetch 0
pkg = File.readlink pkg if File.exists? pkg

config = [{
	id: "/marathon-etcd",
	instances: 1,
	
	cpus: 0.01,
	mem: 20,
	disk: 0,
	
	ports: [],
	
	cmd: <<-EOS,
		set -ea
		source /etc/kevincox-environment
		source /etc/marathon-etcd
		
		nix-store -r #{pkg} --add-root pkg --indirect
		
		exec sudo -E -umarathon-etcd \
			#{pkg}/bin/marathon-etcd
	EOS
	user: "root",
}]

http = Net::HTTP.new "marathon.kevincox.ca", 443
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_NONE
http.cert = OpenSSL::X509::Certificate.new File.read "/home/kevincox/p/nix/secret/ssl/s.kevincox.ca.crt"
http.key = OpenSSL::PKey::RSA.new File.read "/home/kevincox/p/nix/secret/ssl/s.kevincox.ca.key"

req = Net::HTTP::Put.new "https://marathon.kevincox.ca/v2/apps"
req.content_type = 'application/json; charset=utf-8'
req.body = JSON.dump config
res = http.request req

p res
puts YAML.dump JSON.parse res.body

exit res.code == 200

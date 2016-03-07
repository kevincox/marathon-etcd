#! /usr/bin/env ruby
#
require 'bundler/setup'

require 'json'
require 'net/http'
require 'openssl'
require 'socket'
require 'thread'

require 'etcd'

MARATHON = ENV.fetch "MARATHON_URL"
CRT = ENV.fetch "MARATHON_CRT"
KEY = ENV.fetch "MARATHON_KEY"

ips = Hash.new do |this, host|
	this[host] = Socket::getaddrinfo(host, nil)[0][3]
end

old = {}

etcd_uris = ENV.fetch('ETCDCTL_PEERS').split(',').map{|u| URI.parse(u)}
crt = OpenSSL::X509::Certificate.new File.read ENV['ETCDCTL_CERT_FILE']
key = OpenSSL::PKey::RSA.new File.read ENV['ETCDCTL_KEY_FILE']
etcd = Etcd.client host:     etcd_uris[0].host,
                   port:     etcd_uris[0].port || 80,
                   use_ssl:  etcd_uris[0].scheme.end_with?('s'),
                   ca_file:  ENV['ETCDCTL_CA_FILE'],
                   ssl_cert: crt,
                   ssl_key:  key

def connect
	http = Net::HTTP.new MARATHON, 443
	http.use_ssl = true
	http.verify_mode = OpenSSL::SSL::VERIFY_NONE
	http.cert = OpenSSL::X509::Certificate.new File.read CRT
	http.key = OpenSSL::PKey::RSA.new File.read KEY
	http
end

def to_json data
	data = data.keys.sort.map {|k| [k, data[k]]}
	JSON.dump Hash[data]
end

mutex = Mutex.new
cond = ConditionVariable.new

Thread.abort_on_exception = true
Thread.new do
	http = connect
	
	loop do
		res = http.request_get "https://#{MARATHON}/v2/apps?embed=apps.tasks"
		data = JSON.load res.body
		new = {}
		data["apps"].each do |app|
			labels = app['labels'] || {}
			next unless labels.include? 'DNS_TYPE'
			id = app['id']
			new_keys = {}
			old_keys = old.fetch id, {}
			
			type = labels.fetch 'DNS_TYPE'
			name = labels.fetch 'DNS_NAME'
			cdn  = %w(1 y yes on).include? labels.fetch('DNS_CDN', '1')
			ttl  = labels.fetch('DNS_TTL', cdn ? 300 : 120).to_i
			
			app['tasks'].each do |task|
				ip = ips[task['host']]
				key = "/services/#{type}-#{name}/#{ip}"
				value = to_json type: type,
				                name: name,
				                value: ip,
				                ttl: ttl,
				                cdn: cdn
				etcd.set key, value: value, ttl: 60
				new_keys[key] = true
				old_keys.delete key
			end
			
			old_keys.each do |k, v|
				etcd.delete k
			end
			
			new[id] = new_keys
		end
		
		old = new
		
		mutex.synchronize { cond.wait mutex, 30 }
	end
end

stream = connect
stream.read_timeout = 24 * 60 * 60
stream.request_get "https://#{MARATHON}/v2/events",
	"Accept" => "text/event-stream" do |res|
	res.read_body do |chunk|
		mutex.synchronize { cond.signal }
	end
end

#! /usr/bin/env ruby
#
require 'bundler/setup'

require 'json'
require 'net/http'
require 'openssl'
require 'pp'
require 'socket'
require 'thread'

require 'etcd'

MARATHON = ENV.fetch "MARATHON_URL"
CRT = ENV.fetch "MARATHON_CRT"
KEY = ENV.fetch "MARATHON_KEY"

ips = Hash.new do |this, host|
	this[host] = Socket::getaddrinfo(host, nil, nil, :STREAM, nil, nil, false)
end

old = {}

etcd_uris = ENV.fetch('ETCDCTL_PEERS').split(',').map{|u| URI.parse(u)}
crt = OpenSSL::X509::Certificate.new File.read ENV.fetch 'ETCDCTL_CERT_FILE'
key = OpenSSL::PKey::RSA.new File.read ENV.fetch 'ETCDCTL_KEY_FILE'
etcd = Etcd.client host:     etcd_uris[0].host,
                   port:     etcd_uris[0].port || 80,
                   use_ssl:  etcd_uris[0].scheme.end_with?('s'),
                   ca_file:  ENV.fetch('ETCDCTL_CA_FILE'),
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
			records = app['labels'].each.select{|k, v| k.start_with? 'kevincox-dns'}
			next if records.empty?
			records.map! do |k, v|
				j = JSON.load v
				
				{
					name: j.fetch('name'),
					cdn:  j.fetch('cdn'),
					ttl:  j.fetch('ttl'),
				}
			end
			
			id = app.fetch 'id'
			new_keys = {}
			old_keys = old.fetch id, {}
			
			healthchecks = app['healthChecks'].length
			
			app['tasks'].each do |task|
				hcs = task.fetch 'healthCheckResults', [].freeze
				next unless hcs && hcs.count{|hc| hc['alive'] } == healthchecks
				
				ips[task['host']].each do |addrinfo|
					type = case addrinfo[0]
					when 'AF_INET'
						'A'
					when 'AF_INET6'
						'AAAA'
					else
						next
					end
					ip = addrinfo[3]
					
					records.each do |rec|
						name = rec[:name]
						ttl = rec[:ttl]
						cdn = rec[:cdn]
						key = "/services/A-#{name}/#{ip}"
						value = to_json type: type,
						                name: name,
						                value: ip,
						                ttl: ttl,
						                cdn: cdn
						etcd.set key, value: value, ttl: 60
						new_keys[key] = true
						old_keys.delete key
					end
				end
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

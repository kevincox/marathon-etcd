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

MARATHON = ENV.fetch 'MARATHON_URL'
USER, _, PASS = ENV.fetch('MARATHON_AUTH').partition ':'

ips = Hash.new do |this, host|
	this[host] = Socket::getaddrinfo(host, nil, nil, :STREAM, nil, nil, false)
end

old = {}

etcd_uris = ENV.fetch('ETCDCTL_PEERS').split(',').map{|u| URI.parse(u)}
crt = OpenSSL::X509::Certificate.new File.read ENV.fetch 'ETCDCTL_CERT_FILE'
key = OpenSSL::PKey.read File.read ENV.fetch 'ETCDCTL_KEY_FILE'
etcd = Etcd.client host:     etcd_uris[0].host,
                   port:     etcd_uris[0].port || 80,
                   use_ssl:  etcd_uris[0].scheme.end_with?('s'),
                   ca_file:  ENV.fetch('ETCDCTL_CA_FILE'),
                   ssl_cert: crt,
                   ssl_key:  key

def connect
	http = Net::HTTP.new MARATHON, 443
	http.use_ssl = true
	http
end

def get path
	req = Net::HTTP::Get.new "https://#{MARATHON}#{path}"
	req.basic_auth USER, PASS
	req
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
		res = http.request get "/v2/apps?embed=apps.tasks"
		data = JSON.load res.body
		new = {}
		data["apps"].each do |app|
			records = app['labels'].each.select{|k, v| k.start_with? 'kevincox-dns'}
			next if records.empty?
			records.map! do |k, v|
				j = JSON.load v
				
				{
					type: j['type'] || 'A',
					name: j.fetch('name'),
					priority: j['priority'] || 10,
					weight: j['weight'] || 100,
					port: j['port'] || 0,
					cdn:  j.fetch('cdn'),
					ttl:  j.fetch('ttl'),
				}
			end
			
			id = app.fetch 'id'
			new_keys = {}
			old_keys = old.fetch id, {}
			
			healthchecks = app['healthChecks'].length
			
			app['tasks'].each do |task|
				records.each do |rec|
					case type = rec.fetch(:type)
					when 'A'
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
					when 'SRV'
						name = rec.fetch :name
						proto = name.partition('.')[0][1, -1]
						port = task.fetch('ports')[rec.fetch(:port)]
						host = task.fetch 'host'
						value = "#{rec[:priority]} #{rec[:weight]} #{port} #{host}"
						
						key = "/services/SRV-#{name}/#{host}:#{port}"
						value = to_json type: type,
						                name: name,
						                value: value,
						                ttl: rec[:ttl],
						                cdn: false
						etcd.set key, value: value, ttl: 60
						new_keys[key] = true
						old_keys.delete key
					else
						$stderr.puts "WRN: Unknown record type #{type.inspect}"
						$stderr.puts "in #{rec.inspect}"
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
req = get "/v2/events"
req['Accept'] = 'text/event-stream'
stream.request req do |res|
	res.read_body do |chunk|
		mutex.synchronize { cond.signal }
	end
end

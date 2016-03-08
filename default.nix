with import <nixpkgs> {}; let
	marathon = [{
		id = "/marathon-etcd";
		instances = 1;
		
		cpus = "JSON_UNSTRING 0.01 JSON_UNSTRING";
		mem = 20;
		disk = 0;
		ports = [];
		
		cmd = ''
			set -ea
			source /etc/kevincox-environment
			source /etc/marathon-etcd
			
			nix-store -r PKG --add-root pkg --indirect
			
			exec sudo -E -umarathon-etcd \
				PKG/bin/marathon-etcd
		'';
		user = "root";
		
		upgradeStrategy = {
			minimumHealthCapacity = 0;
			maximumOverCapacity = 0;
		};
	}];
in stdenv.mkDerivation {
	name = "marathon-etcd";
	
	outputs = ["out" "marathon"];
	
	meta = {
		description = "Keep etcd dns records in sync with marathon tasks.";
		homepage = https://kevincox.ca;
	};
	
	src = builtins.filterSource (name: type:
		(lib.hasPrefix (toString ./Gemfile) name) ||
		(lib.hasPrefix (toString ./bin) name)
	) ./.;
	
	SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
	
	buildInputs = [ ruby bundler makeWrapper ];
	
	buildPhase = ''
		bundle install --standalone
		rm -r bundle/ruby/*/cache/
	'';
	
	installPhase = ''
		mkdir -p "$out"
		cp -rv bundle "$out"
		install -Dm755 bin/marathon-etcd.rb "$out/bin/marathon-etcd"
		
		wrapProgram $out/bin/marathon-etcd \
			--set RUBYLIB "$out/bundle"
		
		# Marathon config.
		install ${builtins.toFile "marathon" (builtins.toJSON marathon)} "$marathon"
		substituteInPlace "$marathon" \
			--replace '"JSON_UNSTRING' "" \
			--replace 'JSON_UNSTRING"' "" \
			--replace PKG "$out"
	'';
}

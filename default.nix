with import <nixpkgs> {}; let
	klib = import (
		builtins.fetchTarball https://github.com/kevincox/nix-lib/archive/master.tar.gz
	);
in rec {
	out = stdenv.mkDerivation {
		name = "marathon-etcd";
		
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
		'';
	};
	
	marathon = klib.marathon.config [{
		id = "/marathon-etcd";
		
		mem = 50;
		
		constraints = [
			["etcd" "LIKE" "v3"]
		];
		
		env-files = [
			"/etc/kevincox-etcd"
			"/run/keys/marathon-etcd"
		];
		exec = [ "${out}/bin/marathon-etcd" ];
		user = "marathon-etcd";
		
		upgradeStrategy = {
			minimumHealthCapacity = 0;
			maximumOverCapacity = 0;
		};
	}];
}

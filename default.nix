with import <nixpkgs> {};

stdenv.mkDerivation {
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
}

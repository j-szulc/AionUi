{
  description = "AionUi — Nix dev shell and standalone server package for OCI composition";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs.lib) genAttrs;
      systems = [ "x86_64-linux" ];
    in
    {
      packages = genAttrs systems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = { };
          };
          lib = pkgs.lib;

          root = ./.;

          # Exclude large or generated trees from the Nix source snapshot.
          src = builtins.path {
            name = "aionui-src";
            path = root;
            filter =
              path: _type:
              let
                p = toString path;
                rootS = toString root;
                r = lib.removePrefix (rootS + "/") p;
              in
              p == rootS
              || (
                !lib.hasPrefix "node_modules/" r
                && r != "node_modules"
                && !lib.hasPrefix "out/" r
                && r != "out"
                && !lib.hasPrefix "dist-server/" r
                && r != "dist-server"
                && !lib.hasPrefix ".git/" r
                && r != ".git"
                && r != "result"
                && !lib.hasPrefix ".direnv/" r
                && r != ".direnv"
              );
          };

          version = (lib.importJSON (root + "/package.json")).version;

          # Fixed-output: full `node_modules` (sandbox-pure). `CI=true` makes
          # scripts/postinstall.js skip `electron-builder install-app-deps`.
          # `--ignore-scripts` avoids native rebuilds; deps like better-sqlite3 use prebuilt binaries.
          bunDeps = pkgs.stdenvNoCC.mkDerivation {
            pname = "aionui-bun-deps";
            inherit version src;
            nativeBuildInputs = [ pkgs.bun ];
            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              export CI=true
              bun install --frozen-lockfile --ignore-scripts
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              mv node_modules "$out/"
              runHook postInstall
            '';

            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            # Update when bun.lock or package.json dependency graph changes (`nix build` will print the expected hash).
            outputHash = "sha256-yY4hJpjxbvxa6NKwPB+uvgJTRstpojAcWRi7bwZS0u8=";
          };

          aionui-app = pkgs.stdenv.mkDerivation {
            pname = "aionui-app";
            inherit version src;

            nativeBuildInputs = [
              pkgs.bun
              pkgs.nodejs_22
            ];

            dontConfigure = true;

            postPatch = ''
              rm -rf node_modules
              cp -R ${bunDeps}/node_modules ./node_modules
              chmod -R u+w ./node_modules
            '';

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              export CI=true
              if ! node ./node_modules/vite/bin/vite.js build --config vite.renderer.config.ts >"$TMPDIR/vite.log" 2>&1; then
                echo "vite build failed; log:" >&2
                tail -n 200 "$TMPDIR/vite.log" >&2
                exit 1
              fi
              node scripts/build-server.mjs
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/opt/aionui"
              cp -r dist-server package.json bun.lock patches "$out/opt/aionui/"
              mkdir -p "$out/opt/aionui/out"
              cp -r out/renderer "$out/opt/aionui/out/"
              # Runtime loads additional assets from src/process/resources/*.
              if [ -d src/process/resources ]; then
                mkdir -p "$out/opt/aionui/src/process"
                cp -r src/process/resources "$out/opt/aionui/src/process/"
              fi
              # Full node_modules (offline); avoid `bun install --production` here — it
              # re-resolves the graph and hits the network in the Nix sandbox.
              cp -R node_modules "$out/opt/aionui/"
              runHook postInstall
            '';

            meta = {
              description = "AionUi standalone server bundle (Bun + Vite renderer + dist-server)";
              license = lib.licenses.asl20;
            };
          };

          aionui-server = pkgs.runCommand "aionui-server"
            {
              nativeBuildInputs = [ pkgs.makeWrapper ];
              meta = aionui-app.meta // {
                mainProgram = "aionui-server";
              };
            }
            ''
              mkdir -p "$out/bin"
              makeWrapper ${pkgs.bun}/bin/bun "$out/bin/aionui-server" \
                --chdir "${aionui-app}/opt/aionui" \
                --add-flags "${aionui-app}/opt/aionui/dist-server/server.mjs"
            '';
        in
        {
          inherit aionui-app aionui-server;
          default = aionui-server;
        }
      );

      devShells = genAttrs systems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = { };
          };
          headlessXdgOpen = pkgs.writeShellScriptBin "xdg-open" ''
            echo "xdg-open is not available in this headless environment." >&2
            exit 1
          '';
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              bun
              nodejs_22
              git
              python3
              headlessXdgOpen
            ];
          };
        }
      );
    };
}

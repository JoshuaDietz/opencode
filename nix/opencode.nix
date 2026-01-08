{
  lib,
  stdenvNoCC,
  bun,
  ripgrep,
  makeBinaryWrapper,
  jq
}:
args:
let
  inherit (args) scripts;
  mkModules =
    attrs:
    args.mkNodeModules (
      attrs
      // {
        canonicalizeScript = scripts + "/canonicalize-node-modules.ts";
        normalizeBinsScript = scripts + "/normalize-bun-binaries.ts";
      }
    );
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "opencode";
  inherit (args) version src;

  node_modules = mkModules {
    inherit (finalAttrs) version src;
  };

  nativeBuildInputs = [
    bun
    makeBinaryWrapper
    jq
  ];

  env.MODELS_DEV_API_JSON = args.modelsDev;
  env.OPENCODE_VERSION = args.version;
  env.OPENCODE_CHANNEL = "stable";
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    cp -r ${finalAttrs.node_modules}/node_modules .
    cp -r ${finalAttrs.node_modules}/packages .

    (
      cd packages/opencode

      chmod -R u+w ./node_modules
      mkdir -p ./node_modules/@opencode-ai
      rm -f ./node_modules/@opencode-ai/{script,sdk,plugin}
      ln -s $(pwd)/../../packages/script ./node_modules/@opencode-ai/script
      ln -s $(pwd)/../../packages/sdk/js ./node_modules/@opencode-ai/sdk
      ln -s $(pwd)/../../packages/plugin ./node_modules/@opencode-ai/plugin

      cp ${./bundle.ts} ./bundle.ts
      chmod +x ./bundle.ts
      bun run ./bundle.ts
    )

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    cd packages/opencode
    if [ ! -d dist ]; then
      echo "ERROR: dist directory missing after bundle step"
      exit 1
    fi

    mkdir -p $out/lib/opencode
    cp -r dist $out/lib/opencode/
    chmod -R u+w $out/lib/opencode/dist

    # Select bundled worker assets deterministically (sorted find output)
    worker_file=$(find "$out/lib/opencode/dist" -type f \( -path '*/tui/worker.*' -o -name 'worker.*' \) | sort | head -n1)
    parser_worker_file=$(find "$out/lib/opencode/dist" -type f -name 'parser.worker.*' | sort | head -n1)
    if [ -z "$worker_file" ]; then
      echo "ERROR: bundled worker not found"
      exit 1
    fi

    main_wasm=$(printf '%s\n' "$out"/lib/opencode/dist/tree-sitter-*.wasm | sort | head -n1)
    wasm_list=$(find "$out/lib/opencode/dist" -maxdepth 1 -name 'tree-sitter-*.wasm' -print)
    for patch_file in "$worker_file" "$parser_worker_file"; do
      [ -z "$patch_file" ] && continue
      [ ! -f "$patch_file" ] && continue
      if [ -n "$wasm_list" ] && grep -q 'tree-sitter' "$patch_file"; then
        # Rewrite wasm references to absolute store paths to avoid runtime resolve failures.
        bun --bun ${scripts + "/patch-wasm.ts"} "$patch_file" "$main_wasm" $wasm_list
      fi
    done

    mkdir -p $out/lib/opencode/node_modules
    cp -r ../../node_modules/.bun $out/lib/opencode/node_modules/
    mkdir -p $out/lib/opencode/node_modules/@opentui

    mkdir -p $out/lib/opencode/node_modules/@opencode-ai
    cp -r ../../packages/plugin $out/lib/opencode/node_modules/@opencode-ai/plugin
    cp -r ../../packages/sdk/js $out/lib/opencode/node_modules/@opencode-ai/sdk  
    cp -r ../../packages/script $out/lib/opencode/node_modules/@opencode-ai/script

    mkdir -p $out/bin
    makeWrapper ${bun}/bin/bun $out/bin/opencode \
      --add-flags "run" \
      --add-flags "$out/lib/opencode/dist/src/index.js" \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
      --argv0 opencode

    runHook postInstall
  '';

postInstall = ''
  # Existing @opentui symlinks
  for pkg in $out/lib/opencode/node_modules/.bun/@opentui+core-* $out/lib/opencode/node_modules/.bun/@opentui+solid-* $out/lib/opencode/node_modules/.bun/@opentui+core@* $out/lib/opencode/node_modules/.bun/@opentui+solid@*; do
    if [ -d "$pkg" ]; then
      pkgName=$(basename "$pkg" | sed 's/@opentui+\([^@]*\)@.*/\1/')
      ln -sf ../.bun/$(basename "$pkg")/node_modules/@opentui/$pkgName \
        $out/lib/opencode/node_modules/@opentui/$pkgName
    fi
  done
  
  # NEW: Dynamically create plugin's node_modules from package.json
  cd $out/lib/opencode/node_modules/@opencode-ai/plugin
  chmod -R u+w . # this allows us to create the symlinks below inside of the existing dirs
  
  # Read dependencies from package.json and create symlinks
  for dep in $(jq -r '.dependencies | keys[]' package.json 2>/dev/null || echo ""); do
    if [[ "$dep" == @* ]]; then
      # Scoped package (e.g., @opencode-ai/sdk)
      scope=$(echo "$dep" | cut -d'/' -f1)
      pkgName=$(echo "$dep" | cut -d'/' -f2)
      
      mkdir -p "node_modules/$scope"
      
      # Check if it's a workspace package (already copied separately)
      if [ -d "../../$pkgName" ]; then
        ln -sf "../../$pkgName" "node_modules/$dep"
      else
        # Find in .bun (scoped packages use + instead of / in .bun)
        bunPkg=$(find ../../.bun -maxdepth 1 -name "$scope+$pkgName@*" -type d 2>/dev/null | head -n1)
        if [ -n "$bunPkg" ]; then
          ln -sf "../../../.bun/$(basename "$bunPkg")/node_modules/$dep" "node_modules/$dep"
        fi
      fi
    else
      # Unscoped package (e.g., zod)
      bunPkg=$(find ../../.bun -maxdepth 1 -name "$dep@*" -type d 2>/dev/null | head -n1)
      if [ -n "$bunPkg" ]; then
        ln -sf "../../../.bun/$(basename "$bunPkg")/node_modules/$dep" "node_modules/$dep"
      fi
    fi
  done
'';


  dontFixup = true;

  meta = {
    description = "AI coding agent built for the terminal";
    longDescription = ''
      OpenCode is a terminal-based agent that can build anything.
      It combines a TypeScript/JavaScript core with a Go-based TUI
      to provide an interactive AI coding experience.
    '';
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.mit;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    mainProgram = "opencode";
  };
})
